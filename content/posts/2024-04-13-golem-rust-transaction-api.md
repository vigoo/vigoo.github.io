+++
title = "Golem's Rust transaction API"

[taxonomies]
tags = ["rust", "golem", "macro"]
+++

## Introduction

A few weeks ago we have added a new set of _host functions_ to [Golem](https://golem.cloud), which allow programs running on this platform to control some of the persistency and transactional behavior of the executor. You can learn about these low-level functions on [the corresponding learn page](https://learn.golem.cloud/docs/transaction-api).

These exported functions allow a lot of control but they are very low level, and definitely not pleasant to use directly. To make them nicer we can write language-specific wrapper libraries on top of them, providing a first class experience for the supported programming languages.

The first such wrapper library is [golem-rust](http://github.com/golemcloud/golem-rust), and this post explains some of the Rust specific technical details of how this library works.

## Regional changes

The easy part is providing higher level support for temporarily changing the executor's behavior. The common property of these host functions is that they come in pairs:

- The `mark-begin-operation`/`mark-end-operation` pair defines a region that is treated as an atomic operation
- We can get the current retry policy and change it to something else with the `get-retry-policy` and `set-retry-policy` functions
- We can control persistency with `get-oplog-persistence-level` and `set-oplog-persistence-level`
- And we can change whether the executor assumes that external calls are idempotent using the `get-idempotence-mode` and `set-idempotence-mode` pair.

For all these, a simple way to make them more safe and more idiomatic is to connect the lifetime of the temporarily changed behavior to the lifetime of a rust variable. For example in the following snippet, the whole function will be treated as an atomic region, but as soon the function returns, the region ends:

```rust
fn some_atomic_operation() {
  let _atomic = golem_rust::mark_atomic_operation();
  // ...
}
```

Implement these wrappers is quite simple. First we need to define _data type_ which the wrapper will return. Let's call it `AtomicOperationGuard`:

```rust
pub struct AtomicOperationGuard {
    begin: OplogIndex,
}
```

We store the return value of Golem's `mark-begin-operation` in it, as we have to pass this value to the `mark-end-operation` when we want to close the atomic region.

We want to close the atomic region when this value is dropped - so we can call Golem's `mark-end-operation` in an explicitly implemented `drop` function:

```rust
impl Drop for AtomicOperationGuard {
    fn drop(&mut self) {
        mark_end_operation(self.begin);
    }
}
```

Finally we define the wrapper function which returns this guard value:

```rust
#[must_use]
pub fn mark_atomic_operation() -> AtomicOperationGuard {
    let begin = mark_begin_operation();
    AtomicOperationGuard { begin }
}
```

By using the `#[must_use]` attribute we can make the compiler give a warning if the result value is not used - this is important, because that would mean that the atomic region gets closed as soon as it has been opened.

With this basic building block we can also support an alternative style where we pass a function to be executed with the temporary change in Golem's behavior. These are higher order functions, taking a function as a parameter, and just using the already defined wrapper to apply the change:

```rust
pub fn atomically<T>(f: impl FnOnce() -> T) -> T {
    let _guard = mark_atomic_operation();
    f()
}
```

The same pattern can be used for all the mentioned host function pairs to get a pair of wrappers (one returning a guard, the other taking a function as a parameter):

- `use_retry_policy` and `with_retry_policy`
- `use_idempotence_mode` and `with_idempotence_mode`
- `use_persistence_level` and `with_persistence_level`

## Transactions

Golem provides **durable execution** and that comes with guarantees that your program will always run until it terminates, and (by default) all external operations are performed _at least once_. (Here _at least once_ is the guarantee we can provide - naturally it does not mean that we just rerun all operations in case of a failure event. Golem tries to perform every operation exactly once but this cannot be guaranteed without special collaboration with the remote host. This behavior can be switched to _at most once_ by changing the **idempotence mode** with the helper functions we defined above.)

Many times external operations (such as HTTP calls to remote hosts) need to be executed _transactionally_. If some of the operations failed the transaction need to be rolled back - **compensation actions** need to undo whatever the already successfully performed operations did.

We identified and implemented two different transaction types - both provide different guarantees and both can be useful.

A **fallible transaction** only deals with domain errors. Within the transaction every **operation** that succeeds gets recorded. If an operation fails, all the recorded operations get _compensated_ in reverse order before the transaction block returns with a failure.

What if anything non-domain specific failure happens to the worker? It can be an unexpected fatal error, hardware failure, an executor restarted because of a deployment, etc. A fallible transaction is completely implemented as regular user code, so Golem's durable execution guarantees apply to it. If for example the executor dies while 3 operation were completed out of the 5 in the transaction, the execution will continue from where it was - continuing with the 4th operation. If the 4th operation fails with a domain error, and the `golem-rust` library starts executing the compensation actions, and then a random failure causes a panic in the middle of this, the execution will continue from the middle of the compensation actions making sure that all the operations are properly rolled back.

Another possibility is what we call **infallible transaction**s. Here we say that the transaction must not fail - but still if a step fails in it, we want to run compensation actions before we retry.

To implement this we need some of the low-level transaction controls Golem provides. First of all, we need to mark the whole transaction as an _atomic region_. This way if a (non domain level) failure happens during the transaction, the previously performed external operations will be automatically retried as the atomic region was never committed.

We can capture the domain errors in user code and perform the compensation actions just like in the _fallible transaction_ case. But what should we do when all operations have been rolled back? We can use the `set-oplog-index` host function to tell Golem to "go back in time" to the beginning of the transaction, forget everything that was performed after it, and start executing the transaction again.

There is a third, more complete version of **infallible transactions** which is not implemented yet - in this version we can guarantee that the compensation actions are performed even in case of a non-domain failure event. This can be implemented with the existing features of Golem but it is out of the scope of this post.

### Operation and Transaction

Let's see how we can implement this transaction feature.

The first thing we need to define is an _operation_ - something that pairs an arbitrary action with a compensation action that undoes it. We can define it as a trait with two methods:

```rust
pub trait Operation: Clone {
    type In: Clone;
    type Out: Clone;
    type Err: Clone;

    /// Executes the operation which may fail with a domain error
    fn execute(&self, input: Self::In) -> Result<Self::Out, Self::Err>;

    /// Executes a compensation action for the operation.
    fn compensate(&self, input: Self::In, result: Self::Out) -> Result<(), Self::Err>;
}
```

If the operation succeeds, its result of type `Out` will be stored - if it fails, `compensate` will be called for all the previous operations with these stored output values.

We also need something that defines the boundaries of a transaction, and allows executing these operations. Here we can create two slightly different interfaces for fallible and infallible transactions - to make it more user friendly.

For fallible transactions we can define a higher order function where the user's logic itself can fail, and in the end we get back a transaction result:

```rust
pub fn fallible_transaction<Out, Err: Clone + 'static>(
    f: impl FnOnce(&mut FallibleTransaction<Err>) -> Result<Out, Err>,
) -> TransactionResult<Out, Err>
```

The result type here is just an alias to the standard Rust `Result` type, in which the error type will be `TransactionFailure`:

```rust
pub type TransactionResult<Out, Err> = Result<Out, TransactionFailure<Err>>;

pub enum TransactionFailure<Err> {
    /// One of the operations failed with an error, and the transaction was fully rolled back.
    FailedAndRolledBackCompletely(Err),
    /// One of the operations failed with an error, and the transaction was partially rolled back
    /// because the compensation action of one of the operations also failed.
    FailedAndRolledBackPartially {
        failure: Err,
        compensation_failure: Err,
    },
}
```

The function we pass to `fallible_transaction` gets a mutable reference to a transaction object - this is what we can use to execute operations:

```rust
struct FallibleTransaction {
  // ...
}

impl<Err: Clone + 'static> FallibleTransaction<Err> {
  pub fn execute<OpIn: Clone + 'static, OpOut: Clone + 'static>(
        &mut self,
        operation: impl Operation<In = OpIn, Out = OpOut, Err = Err> + 'static,
        input: OpIn,
    ) -> Result<OpOut, Err>
}
```

This looks a bit verbose but all it says is you can pass an arbitrary `Operation` to this function, but all of them needs to have the same failure type, and you provide an \_input_value for your operation. This separation of operation and input makes it possible to define reusable operations by implementing the `Operation` trait manually - we will see more ways to define operations later.

We also define a similar function and corresponding data type for _infallible transactions_. There are two main differences:

- The `infallible_transaction` function's result type is simply `Out` - it can never fail
- Similarly, `execute` it self cannot fail and this means that the transactional function itself cannot fail - and no need to use `?` or other ways to deal with result types.

Storing the compensation actions in these structs is easy - we can just create closures capturing the input and output values and calling the trait's `compensate` function, and store these closures in a vec:

```rust
struct CompensationAction<Err> {
    action: Box<dyn Fn() -> Result<(), Err>>,
}

impl<Err> CompensationAction<Err> {
    pub fn execute(&self) -> Result<(), Err> {
        (self.action)()
    }
}

pub struct FallibleTransaction<Err> {
    compensations: Vec<CompensationAction<Err>>,
}
```

A last thing we can do in this level of the API is to think about cases where one would write generic code that works both with fallible and infallible transactions. Using a unified interface would not be as nice as using the dedicated one - as it deal with error types even if the transaction can never fail - but may provide better code reusability. We can hide the difference by defining a trait:

```rust
pub trait Transaction<Err> {
    fn execute<OpIn: Clone + 'static, OpOut: Clone + 'static>(
        &mut self,
        operation: impl Operation<In = OpIn, Out = OpOut, Err = Err> + 'static,
        input: OpIn,
    ) -> Result<OpOut, Err>;

    fn fail(&mut self, error: Err) -> Result<(), Err>;

    fn run<Out>(f: impl FnOnce(&mut Self) -> Result<Out, Err>) -> TransactionResult<Out, Err>;
}
```

The trait provides a way to execute operations and explicitly fail the transaction, and it also generalizes the `fallible_transaction` and `infallible_transaction` function with a static function called `run`. Implementing this interface for our two transaction types is straightforward.

### Defining operations

We defined an `Operation` trait but haven't talked yet about how we will declare new operations. One obvious way is to define a type and implement the trait for it:

```rust
struct CreateAccount {
  // configuration
}

impl Operation for CreateAccount {
    type In  = AccountDetails;
    type Out = AccountId;
    type Err = DomainError;

    fn execute(&self, input: AccountDetails) -> Result<AccountId, DomainError> {
      todo!("Create the account")
    }

    fn compensate(&self, input: AccountDetails, result: AccountId) -> Result<(), Self::Err> {
      todo!("Delete the account");
    }
}
```

The library provides a more concise way to define ad-hoc operations by just passing two functions:

```rust
pub fn operation<In: Clone, Out: Clone, Err: Clone>(
    execute_fn: impl Fn(In) -> Result<Out, Err> + 'static,
    compensate_fn: impl Fn(In, Out) -> Result<(), Err> + 'static,
) -> impl Operation<In = In, Out = Out, Err = Err> { ... }

// ...

let op = operation(
  move |account_details: AccountDetails| {
    todo!("Create the account")
	},
  move |account_details: AccountDetails, account_id: AccountId| {
    todo!("Delete the account")
  });
```

Under the hood this creates a struct called `FnOperation` storing these two closures in it.

There is a third way though. Let's see how it looks like, and then explore how it can be implemented with _Rust macros_!

```rust
#[golem_operation(compensation=delete_account)]
fn create_account(username: &str, email: &str) -> Result<AccountId, DomainError> {
  todo!("Create the account")
}

fn delete_account(account_id: AccountId) -> Result<(), DomainError> {
  todo!("Delete the account")
}

// ...

infallible_transaction(|tx| {
  let account_id = tx.create_account("vigoo", "x@y");
  // ...
});
```

### Operation macro

In the above example `golem_operation` is a macro. It is a function executed compile time that takes the annotated item - in this case the `create_account` function and **transforms** it to something else.

The first thing to figure out when writing a macro like that is what exactly we want to transform the function into. Let's see what this macro generates, and then I explain how to get there.

If we expand the macro for the above example we get the following:

```rust
fn create_account(username: &str, email: &str) -> Result<AccountId, DomainError> {
    todo!("Create the account")
}

trait CreateAccount {
  fn create_account(self, username: &str, email: &str) -> Result<AccountId, DomainError>;
}

impl<T: Transaction<DomainError>> CreateAccount for &mut T {
    fn create_account(self, username: &str, email: &str) -> Result<AccountId, DomainError> {
        self.execute(
          operation(
            |(username, email): (&str, &str)| {
              create_account(username, email)
            },
            |(username, email): (&str, &str), op_result: AccountId| {
    	        call_compensation_function(
                delete_account,
                op_result,
                (username, email)
              ).map_err(|err| err.0)
        }), (username, email))
    }
}
```

So seems like the macro leaves the function in its original form, but generates some additional items: a _trait_ which contains the same function signature as the annotated one, and then an _implementation_ for this trait for any `&mut T` where `T` is a `Transaction<DomainError>`.

As I explained above, `Transaction` is a trait that provides a unified interface for both the fallible and infallible transactions. With this instance we define an **extension method** for the `tx` value we get in our transaction functions - this is what allows us to write `tx.create_account` in the above example.

Two more details to notice:

- Our `Operation` type deals with a single input value but our annotated function can have arbitrary number of parameters. We can solve this by defining the operation's input as a **tuple** containing all the function parameters.
- The compensation function (`delete_action`) is not called directly, but through a helper called `call_compensation_function`. This allows us to support compensation functions of different shapes, and I will explain how it works in details.

#### Defining the macro and parsing the function

This type of Rust macro which is invoked by annotating items in the code is called a [proc-macro](https://doc.rust-lang.org/reference/procedural-macros.html). We need to create a separate Rust _crate_ for defining the macro, and set `proc-macro = true` in its `Cargo.toml` file and then create a top-level function annotated with `#[proc_macro_attribute]` to define our macro:

```rust
#[proc_macro_attribute]
pub fn golem_operation(attr: TokenStream, item: TokenStream) -> TokenStream {
  // ...
}
```

Rust macros are transformations on **token streams**. The first parameter of our macro gets the _parameters_ passed to the macro - so in our example it will contain a stream of tokens representing `compensation=delete_account`. The second parameter is the annotated item itself - in our case it's a stream of tokens of the whole function definition including its body.

The result of the function is also a token stream and the easiest thing we can do is to just return `item`:

```rust
#[proc_macro_attribute]
pub fn golem_operation(attr: TokenStream, item: TokenStream) -> TokenStream {
  item
}
```

This is a valid macro that does not do anything.

We somehow have to generate a trait and a trait implementation with only having these two token streams. Before we can generate anything we need to understand the annotated function - we need its name, its parameters, its result type etc.

We can use the [syn](https://docs.rs/syn/latest/syn/) create for this to parse the stream of tokens into a Rust AST.

To parse `item` as a function, we can write:

```rust
let ast: ItemFn = syn::parse(item).expect("Expected a function");
```

This is something we can extract information from, for example `ItemFn` has the following contents:

```rust
pub struct ItemFn {
  pub attrs: Vec<Attribute>,
  pub vis: Visibility,
  pub sig: Signature,
  pub block: Box<Block>,
}
```

And `sig` contains things like the function's name, parameters and return type. It is important to keep in mind though that this is just a parsed AST from the tokens - the whole transformation runs before any type checking and we don't have any way to identify actual Rust types. We only see what's in the source code.

For example in our macro we expect that the annotated function returns with a `Result` type and we need to look into this type because we will use the success and error types in separate places in the generated code.

We cannot do this in a 100% reliable way. We can look for things like the result type _looks like_ a `Result<Out, Err>`, and we may support some additional forms such as `std::result::Result<Out, Err>`, but if the user defined a type alias and uses that, a macro that looks at the AST cannot know that it is equal to a result type. In many cases these limitations can be solved by applying type level programming - we could have a trait that extracts the success and error types of a `Result` and is not implemented for any other type, and then generate code from the macro that uses these helper types.

The current implementation of the `golem_operation` macro does not do this for determining the result types, so it has this limitation that it only works if you use the "standard" way of writing `Result<Out, Err>`.

This looks like the following:

```rust
fn result_type(ty: &Type) -> Option<(Type, Type)> {
      match ty {
        Type::Group(group) => result_type(&group.elem),
        Type::Paren(paren) => result_type(&paren.elem),
        Type::Path(type_path) => {
					let idents = type_path.path.segments.iter().map(|segment| segment.ident.to_string()).collect::<Vec<_>();
          if idents == vec!["Result"] { // ... some more cases
            let last_segment = type_path.path.segments.last().unwrap();
            let syn::PathArguments::AngleBracketed(generics) = &last_segment.arguments else { return None };
            if generics.args.len() != 2 {
              return None;
            }
            let syn::GenericArgument::Type(success_type) = &generics.args[0] else {
              return None;
            };
            let syn::GenericArgument::Type(err_type) = &generics.args[1] else {
              return None;
						};
            Some((success_type.clone(), err_type.clone()))
          }
        // ... other cases returning None
}
```

Once we have all the information we need - the function's name, its parameters, the successful and failed result types, all in `syn` AST nodes, we can generate the additional code that we can return in the end as the new token stream.

To generate token stream we use the [quote library](https://docs.rs/quote/latest/quote/). This library provides the `quote!` macro, which itself generates a `TokenStream` . (Although it is not the same `TokenStream` as the one we need to return from the macro. The macro requires `proc_macro::TokenStream` and `quote!` returns `proc_macro2::TokenStream`. Fortunately it can be simply converted with `.into()`).

We write a single `quote!` for producing the result of the macro:

```rust
let result = quote! {
  #ast

  trait #traitname {
    #fnsig;
  }

  impl<T: golem_rust::Transaction<#err>> #traitname for &mut T {
    #fnsig {
      self.execute(
        golem_rust::#operation(
          |#input_pattern| {
            #fnname(#(#input_args), *)
          },
          |#compensation_pattern| {
            #compensate(
              #compensation,
              (op_result,),
              (#(#compensation_args), *)
            ).map_err(|err| err.0)
          }
        ),
        (#(#input_args), *)
      )
    }
  }
};

result.into() // proc_macro2::TokenStream to proc_macro::TokenStream
```

All the parts prefixed with `#` are references to rust variables outside of the quote, and they can be (and usually are) various `syn` AST nodes or raw token streams.

There is a special syntax for interpolating sequences of values. The case used in the above example is when you write `#(#var), *`. This means that `var` is expected to be an iterable variable (in our case it will be `Vec<_>` usually) and it interpolates each elements by inserting extra tokens, defined between `)` and `*`, between these elements. So this example would insert a comma and a space between the elements.

The above defined `quote` is a template that matches what we wanted to generate. All that's needed is to define all these variables holding dynamic parts of the generated code. The `#ast` variable itself is the parsed function - so the first line of the quote just makes sure the original definition is part of the result.

The `#succ` and `#err` types are extracted with the `result_type` helper function as described above. The others are just defined by either transforming and cloning AST nodes, or using `quote!` to generate sub token streams.

Let's see a few examples!

The new trait's name has to be an `Ident`:

```rust
let fnname = fnsig.ident.clone();
let traitname = Ident::new(&fnname.to_string().to_pascal_case(), fnsig.ident.span());
```

Here we use the `to_pascal_case` extension method provided by the [heck crate](https://docs.rs/heck/latest/heck/).

Another example is the signature of the function that's inside the trait. It is _almost_ the same as the annotated feature, but it has to have a `self` parameter as the first parameter of it, that's how it becomes an extension method on the transaction.

We can do this by cloning the annotated function's signature and just adding a new parameter:

```rust
let mut fnsig = ast.sig.clone();
fnsig.inputs.insert(0, parse_quote! { self });
```

Note that `parse_quote!` immediately parses the token stream generated by quote back to a `syn` AST node.

#### Compensation function shapes

The last interesting bit is how the macro supports compensation functions of different shapes. What we support right now, is the following.

- The compensation function has no parameters at all
- The compensation function takes the output of the action but not the inputs
- The compensation function takes the output and all the inputs

With the account creation example this means all of these are valid:

```rust
#[golem_operation(compensation=delete_account)]
fn create_account(username: &str, email: &str) -> Result<AccountId, DomainError>;

fn delete_account() -> Result<(), DomainError>;
fn delete_account(account_id: AccountId) -> Result<(), DomainError>;
fn delete_account(account_id: AccountId, username: &str, email: &str) -> Result<(), DomainError>;
```

If we could have the AST of `delete_account` from the macro, it would be easy to decide which shape we have - we would not even need to worry about not having actual types because we could just compare the parameter list and result type tokens of the two functions to be able to decide which way to go.

Unfortunately our macro is on the `create_account` function and there is no way to access anything else about `delete_account` from it than the `compensation=delete_account` part which we passed as an attribute parameter.

Before solving this problem let's see how we can get the _name_ of the compensation function, at least:

```rust
let args = parse_macro_input!(args with Punctuated::<Meta, syn::Token![,]>::parse_terminated);

let mut compensation = None;
for arg in args {
  if let Meta::NameValue(name_value) = arg {
    let name = name_value.path.get_ident().unwrap().to_string();
    let value = name_value.value;

    if name == "compensation" {
      compensation = Some(value);
    }
  }
}
```

We parse the macro's input into a list of `Meta` nodes, and look for the `NameValue` cases representing the attribute arguments having the `x=y` form. If the key is `compensation` we store the value, which has the type `Expr` (expression AST node) and we can interpolate this expression node directly in the quoted code to get our function name.

Let's go back to the primary problem - how can we generate code that invokes this function which can have three different shapes, if we cannot know which one it is?

First we define a **trait** that abstracts this problem for us:

```rust
pub trait CompensationFunction<In, Out, Err> {
  fn call(self, result: Out, input: In) -> Result<(), Err>;
}
```

This always has the same shape - we just pass both the results and the inputs to it, and the trait's implementation can decide to use any of these parameters to actually call the compensation function or not.

We can define a function that takes an arbitrary value `T` for which we have an implementation of this trait, and just call it:

```rust
pub fn call_compensation_function<In, Out, Err>(
    f: impl CompensationFunction<In, Out, Err>,
    result: Out,
    input: In,
) -> Result<(), Err> {
    f.call(result, input)
}
```

With this, we can simply generate code from the macro that passes **the actual compensation function** to the `f` parameter of `call_compensation_function`, and always pass both the result and the input!

```rust
call_compensation_function(
  delete_account,
  op_result,
  (username, email)
)
```

To make this work we need instances of `CompensationFunction` for arbitrary function types.

Let's try to define it for the function with no parameters (the first supported shape):

```rust
impl<F, Err> CompensationFunction<(), (), Err> for F
where
    F: FnOnce() -> Result<(), Err>,
{
    fn call(
        self,
        _result: (),
        _input: (),
    ) -> Result<(), (Err,)> {
        self()?;
        Ok(())
    }
}
```

This is not the final implementation as we will see soon. If we try to write an implementation for the second shape - where we only use the result and not the input, we immediately run into a problem:

```rust
impl<F, Out, Err> CompensationFunction<(), Out, Err> for F
where
    F: FnOnce(Out) -> Result<(), Err> {
      // ...
}
```

The error is about **conflicting implementations** of our trait:

```
error[E0119]: conflicting implementations of trait `CompensationFunction<(), (), _>`
  --> golem-rust/src/transaction/compfn.rs:45:1
   |
31 | / impl<F, Err> CompensationFunction<(), (), Err> for F
32 | | where
33 | |     F: FnOnce() -> Result<(), Err>,
   | |___________________________________- first implementation here
...
45 | / impl<F, Out, Err> CompensationFunction<(), Out, Err> for F
46 | | where
47 | |     F: FnOnce(Out) -> Result<(), Err>,
   | |______________________________________^ conflicting implementation
```

These. two trait implementations **overlap**. Although it is not obvious at first glance why the two are overlapping, what happens is all the types involved in the overlap check can be unified:

- The trait's parameters -
  - the first is `()` in both cases
  - The second is `()` vs `Out`. Nothing prevents `Out` to be `()`
  - The third can be anything in both cases
- The type we implement the trait for
  - This is the confusing part - as we have two different function type signatures in the two cases! But these are only type bounds. We say we implement `CompensationFunction` for a type `F` which implements the trait `FnOnce() ...`. The problem is that in theory there can be a type that implements both these function traits, so this is not preventing the overlap either.

This is something [specialization](https://github.com/rust-lang/rfcs/blob/master/text/1210-impl-specialization.md) would solve but that is currently an unstable compiler feature.

If at least one of the above types could not be unified, we would not have an overlap, so that's what we have to do. The simplest way to do so is to stop having unconstrained types in the trait's type parameters such as `In` and `Out` and `Err` (Actually `Err` should not be affected by this, but I applied the same technique to all parameters at once in the library. This is something that could be potentially simplified in the future.).

So we just have to have a type parameter that can contain an arbitrary input or output type, but does not unify with `()`. We can do that by wrapping the output type in a tuple:

```rust
impl<F, Out, Err> CompensationFunction<(), (Out,), (Err,)> for F
  where
    F: FnOnce(Out) -> Result<(), Err>
```

Here instead of `Out` we use `(Out,)` which is a 1-tuple wrapping our output type. This no longer unifies with `()` so the compiler error is solved!

We can imagine additional trait implementations for one or more input parameters:

```rust
impl<F, T1, Out, Err> CompensationFunction<(T1,), (Out,), (Err,)> for F
  where
    F: FnOnce(Out, T1) -> Result<(), Err>,

impl<F, T1, T2, Out, Err> CompensationFunction<(T1,T2), (Out,), (Err,)> for F
  where
    F: FnOnce(Out, T1, T2) -> Result<(), Err>

// ...
```

Two more problems to solve before we are done!

The first problem occurs when we try to use this mechanism for the first to compensation function shapes - when the result, or the result and the input are not used by the function.

The problem is that these trait implementations bind the `In` and/or `Out` types to `()` in these cases, which means that our `call` function will use the unit type for these parameters. For example for `delete_account` which does not takes the input parameters, it would have the following types if we replace the generic parameters with the inferred ones:

```rust
pub fn call_compensation_function(
    f: impl FnOnce(AccountId) -> Result<(), DomainError>,
    result: AccountId,
    input: (),
) -> Result<(), DomainError>
```

And our macro will call it like this:

```rust
call_compensation_function(
  delete_account,
  op_result,
  (username, email)
)
```

This of course will not compile, because we pass `(&str, &str)` in place of a `()`.

Let's take a step back, and change our `CompensationFunction` trait:

```rust
pub trait CompensationFunction<In, Out, Err> {
  fn call(
    self,
    result: impl TupleOrUnit<Out>,
    input: impl TupleOrUnit<In>
  ) -> Result<(), Err>;
}

```

Instead of directly taking `Out` and `In` in the parameters we now accept **anything that implements TupleOrUnit** for the given type.

`TupleOrUnit` is just a special conversion trait:

```rust
pub trait TupleOrUnit<T> {
    fn into(self) -> T;
}
```

What makes it special and what makes it solve our problem is what instances we have for it.

First of all we say that **anything can be converted to unit**:

```rust
impl<T> TupleOrUnit<()> for T {
    fn into(self) {}
}
```

Then we use the same trick to avoid overlapping instances, and we say that 1-tuple, 2-tuple, etc. can be converted to itself only:

```rust
impl<T1> TupleOrUnit<(T1, )> for (T1, ) {
    fn into(self) -> (T1, ) {
        self
    }
}
impl<T1, T2> TupleOrUnit<(T1, T2, )> for (T1, T2, ) {
    fn into(self) -> (T1, T2, ) {
        self
    }
}
// ...
```

With this we achieved that the `call_compensation_function` function is still type safe - it requires us to pass the proper `Out` and `In` types - but in the special case when either of these types are unit, it allows us to pass an arbitrary value instead of an actual `()`.

This makes our macro complete.

The last thing to solve is to have enough instances of these two type classes - `CompensationFunction` and `TupleOrUnit` so our library works with more than 1 or 2 parameters. Writing them by hand is an option but we can easily generate them with another macro!

This time we don't have to write a procedural macro - we can use a **declarative macro**s which are simpler, and they can be defined inline in the same module where we define these types.

Let's start with `TupleOrUnit` as it is a bit simpler. We use the [macro_rules](https://doc.rust-lang.org/reference/macros-by-example.html) macro which is basically a pattern match with a special syntax - you can match on what is passed to the macro, and generate code with interpolation similar to the `quote!` macro - but using `$` instead of `#` as the interpolation symbol. The following definition defines an instance of `TupleOrUnit`:

```rust
macro_rules! tuple_or_unit {
    ($($ty:ident),*) => {
        impl<$($ty),*> TupleOrUnit<($($ty,)*)> for ($($ty,)*) {
            fn into(self) -> ($($ty,)*) {
                self
            }
        }
    }
}
```

We have a single case of our pattern match, which matches a **comma-separated list of identifiers**. We can refer to this list of identifiers as `ty`. Then we use the same syntax for interpolating sequences into the code as we have seen already in our procedural macro and just generate the instance.

We can call this macro with a list of type parameters (which are all _identifiers_):

```rust
tuple_or_unit!(T1, T2, T3);
```

Let's do the same for generating `CompensationFunction` instances:

```rust
macro_rules! compensation_function {
    ($($ty:ident),*) => {
        impl<F, $($ty),*, Out, Err> CompensationFunction<($($ty),*,), (Out,), (Err,)> for F
        where
            F: FnOnce(Out, $($ty),*) -> Result<(), Err>,
        {
            fn call(
                self,
                out: impl TupleOrUnit<(Out,)>,
                input: impl TupleOrUnit<($($ty),*,)>,
            ) -> Result<(), (Err,)> {
                #[allow(non_snake_case)]
                let ( $($ty,)+ ) = input.into();
                let (out,) = out.into();
                self(out, $($ty),*).map_err(|err| (err,))
            }
        }
    }
}
```

The only interesting part here is how we access the components of our tuple.

Let's imagine we pass `T1, T2, T3` as arguments to this macro, so `ty` is a sequence of three identifiers. We can interpolate this comma separated list into the type parameter part (`impl<F, $($ty),*, Out, Err>`) without any problems but this is still just a list of identifiers - and when we call our compensation function (`self`), we have to access the individual elements of this tuple and pass them to the function as separate parameters.

We could write it by hand like this:

```rust
fn call(self, out: impl TupleOrUnit<(Out,)), input: impl TupleOrUnit<(T1, T2, T3)>) -> Result<(), Err> {
  let out: Out = out.into();
  let input: (T1, T2, T3) = input.into();
  self(out, input.0, input.1, input.2)
}
```

It is possible to generate a list of accessors like this from a procedural macro, but not in a declarative one - we only have `ty` to work with. We can instead **destructure** the tuple and we can actually reuse the list of identifiers to do so!

In the above macro code, this can be seen as:

```rust
#[allow(non_snake_case)]
let ( $($ty,)+ ) = input.into();
self(out, $($ty),*)
```

This translates to

```rust
#[allow(non_snake_case)]
let (T1, T2, T3) = input.into();
self(out, T1, T2, T3)
```

The error mapping is only necessary because currently the error typed is also wrapped into a tuple - this could enable additional function shapes where the compensation function never fails, for example, but it is not implemented yet.

## Conclusion

The library described here is open source and is available [on GitHub](https://github.com/golemcloud/golem-rust) and published [to crates.io](https://crates.io/crates/golem-rust). Documentation and examples will soon be added to [Golem's learn pages](https://learn.golem.cloud/docs/intro). And of course this is just a first version I hope to see grow based on user feedback.

We also plan to have similar higher-level wrapper libraries for Golem's features for the other supported languages - everything Golem provides is exposed through the WASM Component Model so any language supporting that have immediate access to the building blocks. All remains is writing idiomatic wrappers on top of them for each language.
