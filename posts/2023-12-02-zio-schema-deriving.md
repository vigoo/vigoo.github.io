---
title: Type class derivation with ZIO Schema
tags: scala derivation zio-schema
---

## Introduction

Making the compiler to automatically _derive_ implementations of a type class for your custom algebraic data types is a common technique in programming languages. Haskell, for example, has built-in syntax for it:

```haskell
data Literal = StringLit String
             | BoolLit Bool
               deriving (Show)
```

and Rust is using macros instantiated by _annotations_ to do the same:

```Rust
#[deriving(Debug)]
enum Literal {
  StringLit(String),
  BoolLit(bool)
}
```

Scala 3 has its own syntax for deriving type classes:

```scala
enum Literal deriving Show:
  case StringLit(value: String)
  case BoolLit(value: Boolean)
```

but the more traditional way that works with Scala 2 as well is to define an implicit in the type's companion object by an explicit macro invocation:

```scala
sealed trait Literal
object Literal {
  final case class StringLit(value: String) extends Literal
  final case class BoolLit(value: String) extends Literal

  implicit val show: Show[Literal] = DeriveShow[Literal]
}
```

All these examples from different languages are common in a way that in order to automatically generate an implementation for an arbitrary type we need to be able to gather information about these types as (compilation-) runtime values, and to generate new code fragments (or actual abstract syntax tree) which then takes part of to the compilation, producing the same result as writing the implementation by hand.

This means using some kind of macro, depending on which programming language we use. But writing these macros is never easy, and in some cases can be very different from the usual way of writing code - so in each programming language people are writing _libraries_ helping type class derivation in one way or the other.

In this post I will show a library like that for Scala, the `Deriver` feature of [ZIO Schema](https://zio.dev/zio-schema/) that I added at the end of last year (2022). But before that let's see a real world example and what alternatives we had.

## Example

[Desert](https://vigoo.github.io/desert/) is a Scala serialization library I wrote in 2020. Not surprisingly in the core of Desert is a _trait_ that describes serialization and deserailization of a type `T`:

```scala
trait BinaryCodec[T] extends BinarySerializer[T] with BinaryDeserializer[T]

trait BinarySerializer[T] {
  def serialize(value: T)(implicit context: SerializationContext): Unit
  // ...
}

trait BinaryDeserializer[T] {
  def deserialize()(implicit ctx: DeserializationContext): T
  // ...
}
```

Although we can implement these traits manually, in order to take advantage of Desert's type evolution capabilities, for complex types like _case classes_ or _enums_ we want the user to be able to write something like this:

```scala
final case class Point(x: Int, y: Int, z: Int)
object Point {
  implicit val codec: BinaryCodec[Point] = DerivedBinaryCodec.derive
}
```

## Alternatives

### Scala 3 mirrors

First of all, **Scala 3** has some built-in support for implementing derivation macros using its `Mirror` type, explained in the [official documentation](https://docs.scala-lang.org/scala3/reference/contextual/derivation.html). We can see a simple example of this technique [in the ZIO codebase](https://github.com/zio/zio/blob/series%2F2.x/test-magnolia/shared/src/main/scala-3/zio/test/magnolia/DeriveGen.scala) where I have implemented a deriving mechanism for the `Gen[R, A]` trait which is Scala 3 specific. (The Scala 2 version is using the Magnolia library, introduced below, which did not have a Scala 3 version back then). The `Mirror` values are summoned by the compiler and they provide the type information:

```scala
inline def gen[T](using m: Mirror.Of[T]): DeriveGen[T] =
  new DeriveGen[T] {
    def derive: Gen[Any, T] = {
      val elemInstances = summonAll[m.MirroredElemTypes]
      inline m match {
        case s: Mirror.SumOf[T]     => genSum(s, elemInstances)
        case p: Mirror.ProductOf[T] => genProduct(p, elemInstances)
      }
    }
  }
```

As this function is an [inline function](https://docs.scala-lang.org/scala3/reference/metaprogramming/inline.html), it gets evaluated compile time, using this summoned `Mirror` value to produce an implementation of `Gen[Any, T]`.

This is a little low level and requires knowledge of inline functions and things like `summonAll` etc., but otherwise a relatively easy way to solve the type class derivation problem. But it is Scala 3 only.

Back in 2020 when I wrote the first version of Desert, there was no Scala 3 at all, and the three main way to do this were

- writing a (Scala 2) macro by hand
- using [Shapeless](https://github.com/milessabin/shapeless)
- using [Magnolia](https://github.com/softwaremill/magnolia)

### Scala 2 macros

Writing a custom derivation logic with Scala 2 macros is not easy, but it is completely possible. It starts by defining a [whitebox macro](https://www.scala-lang.org/api/2.13.12/scala-reflect/scala/reflect/macros/whitebox/Context.html):

```scala
object Derive {
  def derive[A]: BinaryCodec[A] = macro deriveImpl[A]

  def deriveImpl[A: c.WeakTypeTag](
    c: whitebox.Context
  ): c.Tree = {
    import c.universe._
    // ...
  }
}
```

The job of `deriveImpl` is to examine the type of `A` and generate a `Tree` that represents the implementation of the `BinaryCodec` trait for `A`. We can start by getting a `Type` value for `A`:

```scala
val tpe: Type = weakTypeOf[A]
```

and then use that to get all kind of information about this type. For example to check if it is a _case class_, we could write

```scala
def isCaseClass(tpe: Type): Boolean = tpe.typeSymbol.asClass.isCaseClass
```

and then try to collect all the fields of that case class:

```scala
val fields = tpe.decls.sorted.collect {
  case p: TermSymbol if p.isCaseAccessor && !p.isMethod => p
}
```

As we can see this is a very direct and low level way to work with the types, much harder then the `Mirror` type we used for Scala 3. Once we gathered all the necessary information for generating the derived type class, we can use _quotes_ to construct fragments of Scala AST:

```scala
val fieldSerializationStatements = // ...

val codec = q"new BinaryCodec[$tpe] {
  def serialize(value: T)(implicit context: SerializationContext): Unit = {
    ..$fieldSerializationStatements
  }
}
```

In the end, this quoted `codec` value is a `Tree` which we can return from the macro.

### Shapeless

[Shapeless](https://github.com/milessabin/shapeless) is a library for _type level programming_ in Scala 2 (and there is a [new version](https://github.com/typelevel/shapeless-3) for Scala 3 too). It provides things like type-level heterogeneous lists and all of operations on them, and it also defines _macros_ that can convert an arbitrary case class into a _generic representation_, which is essentially a type level list containing all the fields. Similarly it can convert an arbitrary sum type (sealed trait in Scala 2) to a generic representation of coproducts. For example the `Point` case class we used in an earlier example would be represented like this:

```scala
final case class Point(x: Int, y: Int, z: Int)

val point: Point = Point(1, 2, 3)
val genericPoint: Int :: Int :: Int :: HNil = // type
  1 :: 2 :: 3 :: HNil // value
val labelledGenericPoint = // type too complex to show here
  ("x" ->> 1) :: ("y" ->> 2) :: ("z" ->> 3) :: HNil // value
```

In connection with type class derivation the idea is that by using Shapeless we no longer have to write macros to extract type information for our types - we can work with these generic representations instead using advanced type level programming techniques. So the complexity of writing macros is replaced with the complexity of doing type level computation.

Let's see how it would look like. First we start by creating a `derive` method that gets the type we are deriving the codec for as a type parameter:

```scala
def derive[T] = // ...
```

This `T` is an arbitrary type, for example our `Point` structure. In order to get its generic representation provided by Shapeless we have to start using type level techniques, by introducing new type parameters for the things we want to calculate (as types) and implicits to drive these computations. The following version, when compiles, will "calculate" the generic representation of `T` as the type parameter `H`:

```scala
def derive[T, H](implicit gen: LabelledGeneric.Aux[T, H]) = {
  new BinaryCodec[T] {
    def serialize(value: T)(implicit context: SerializationContext): Unit = {
      val h: H = gen.to(value) // generic representation of (value: T)
      // ...
    }
    // ...
  }
}
```

This is not that hard yet but we need to recursively summon implicit codecs for our fields, so we can't just use this `H` value to go through all the fields in a traditional way - we need to traverse it on the type level.

To do that we need to write our own type level computations implemented as implicit instances for `HNil` and `::` etc. The serialization part of the codec would look something like this:

```scala
implicit val hnilSerializer: BinarySerializer[HNil] =
  new BinarySerializer[HNil] {
    def serialize(value: HNil)(implicit context: SerializationContext) => {
      // no (more) fields
    }
  }

implicit def hlistSerializer[K <: Symbol, H, T <: HList](implicit
  witness: Witness.Aux[K] // type level extraction of the field's name
  headSerializer: BinarySerializer[H] // type class summoning for the field
  tailSerializer: BinarySerializer[T] // hlist recursion
): BinarySerializer[FieldType[K, H] :: T] = // ...
```

Similar methods have to be implemented for coproducts too, and also in the codec example we would have to simultaneously derive the serializer _and_ the deserializer. A real implementation would also require access to the _annotations_ of various fields to drive the serialization logic, which requires more and more type level calculations and complicates these type signatures.

I did chose to use Shapeless in the first version of Desert, and the real `derive` method has the following signature:

```scala
  def derive[T, H, Ks <: HList, Trs <: HList, Trcs <: HList, KsTrs <: HList, TH](implicit
      gen: LabelledGeneric.Aux[T, H],
      keys: Lazy[Symbols.Aux[H, Ks]],
      transientAnnotations: Annotations.Aux[transientField, T, Trs],
      transientConstructorAnnotations: Annotations.Aux[transientConstructor, T, Trcs],
      taggedTransients: TagTransients.Aux[H, Trs, Trcs, TH],
      zip: Zip.Aux[Ks :: Trs :: HNil, KsTrs],
      toList: ToTraversable.Aux[KsTrs, List, (Symbol, Option[transientField])],
      serializationPlan: Lazy[SerializationPlan[TH]],
      deserializationPlan: Lazy[DeserializationPlan[TH]],
      toConstructorMap: Lazy[ToConstructorMap[TH]],
      classTag: ClassTag[T]
  ): BinaryCodec[T]
```

Although this works, there are many problems with this approach. All these type and implicit resolutions can make the compilation quite slow, the code is very complex and hard to understand or modify, and most importantly error messages will be a nightmare. A user trying to derive a type class for our serialization library should not get an error that complains about not being able to find an implicit value of `Zip.Aux` for a weird type that does not even fit on one screen!

### Magnolia

The [Magnolia](https://github.com/softwaremill/magnolia) library provides a much more friendly solution for deriving type classes for algebraic data types - it moves the whole problem into the value space by hiding the necessary macros. The derivation implementation for a given type class then only requires defining two functions (one for working with products, one for working with coproducts) that are regular Scala functions getting a "context" value and producing an instance of the derived type class. The context value contains type information - for example the name and type of all the fields of a case class - and also contains an _instance_ of the derived type class for each of these inner elements.

To write a Magnolia based deriver you have to create an `object` with a `join` and a `split` method and a `Typeclass` type:

```scala
object BinaryCodecDerivation {
  type Typeclass[T] = BinaryCodec[T]

  def join[T](ctx: CaseClass[BinaryCodec, T]): BinaryCodec[T] =
    new BinaryCodec[T] {
      def serialize(value: T)(implicit context: SerializationContext) => {
        for (parameter <- ctx.parameters) {
          // recursively serialize the fields
          parameter.typeclass.serialize(parameter.dereference(value))
        }
        // ...
      }
    }

  def split[T](ctx: SealedTrait[BinaryCodec, T]): BinaryCodec[T] =
    // ...

  def gen[T]: BinaryCodec[T] = macro Magnolia.gen[T]
}
```

There is a Magnolia version for Scala 3 too, which is although quite similar, it is not source compatible with the Scala 2 version, leading to the need to define these derivations twice in cross-compiled projects.

## Why not Magnolia?

Magnolia already existed when I wrote the first version of Desert, but I could not use it because of two reasons. In that early version of the library the derivation had to take a user defined list of _evolution steps_, so the actual codec definitions looked something like this:

```scala
object Point {
  implicit val codec: BinaryCodec[Point] = BinaryCodec.derive(FieldAdded[Int]("z", 1))
}
```

It was not clear how could I pass these parameters to Magnolia context - with Shapeless it was not a problem because it is possible to simply pass them as a parameter to the `derive` function that "starts" the type level computation.

This requirement no longer exists though, as in recent versions the _evolution steps_ are defined by attributes, which are fully supported by Magnolia as well:

```scala
@evolutionSteps(FieldAdded[Int]("z", 1))
final case class Point(x: Int, y: Int, z: Int)
```

The second reason was a much more important limitation in Magnolia that still exists - it is not possible to shortcut the derivation tree. Desert has _transient field_ and _transient constructor_ support. For those fields and constructors which are marked as transient we don't want to, and cannot define codec instances. They can be things like open files, streams, actor references, sockets etc. Even though Magnolia only instantiates the type class instances when they are accessed, the derivation fails if there are types in the tree that does not have an instance. This issue is [tracked here](https://github.com/softwaremill/magnolia/issues/297).

There was one more decision I did not like regarding Magnolia - the decision to have an incompatible Scala 3 version. I believe it was a big missed opportunity to seamlessly support cross-compiled type class derivation code.

## ZIO Schema based derivation

All these issues lead to writing a new derivation library - as part of the [ZIO Schema](https://zio.dev/zio-schema/) project. It was first released in version [v0.3.0](https://github.com/zio/zio-schema/releases/tag/v0.3.0) in November of 2022.

From the previously demonstrated type class derivation techniques the closest to ZIO Schema's deriver is Magnolia. On the other hand it does supports the transient field use case, and it is fully cross-compilation compatible between Scala 2 and Scala 3.

To implement type class derivation based on ZIO Schema you need to implement a trait called `Deriver`:

```scala
trait Deriver[F[_]] {
  def deriveRecord[A](
    record: Schema.Record[A],
    fields: => Chunk[WrappedF[F, _]],
    summoned: => Option[F[A]]
  ): F[A]

  // more deriveXXX methods to impelment
}
```

This looks similar to Magnolia's `join` method but has some significant differences. The first thing to notice is that we get a `Schema.Record` value describing our case class. This is one of the cases of the core data type `Schema[T]` which describes Scala data types and provides a lot of features to work with them. So having a `Schema[A]` is a requirement to derive an `F[A]` with `Deriver` - but luckily ZIO schema has derivation support for Schema itself.

The second thing to notice is that `Schema[A]` itself does not know anything about type class derivation and especially about the actual `F` type class that is being derived, so the second parameter of `deriveRecord` is a collection of potentially derived instances of our derived type class for each field. `WrappedF` is just making this lazy so if we decide we don't need instances for (some of) the fields they won't be traversed (they still need to have a `Schema` though - but it can even be a `Schema.fail` for things not representable by ZIO Schema - it will be fine if we never touch them by unwrapping the `WrappedF` value).

The third parameter is also interesting as it provides full control to the developer to choose between the summoned implicit and the derivation logic. If your `deriveRecord` is called for a record type `A` and there is already an implicit `F[A]` that the compiler can find (for example defined in `A`'s companion object), it will be passed in the `summoned` parameter to `deriveRecord`. The usual logic is to choose the summoned value when it is available and only derive an instance when there isn't any. By calling `.autoAcceptSummoned` on our `Deriver` class we can automatically enable this behavior - in this case `deriveRecord` will only be called for the cases where `summoned` was `None`.

Another method we have on `Deriver` is `.cached` which stores the generated type class instances in a concurrent hash map shared between the macro invocations.

Our ZIO Schema based Desert codec derivation is defined using these modifiers:

```scala
object DerivedBinaryCodec {
  lazy val deriver = BinaryCodecDeriver().cached.autoAcceptSummoned

  private final case class BinaryCodecDeriver() extends Deriver[BinaryCodec] {
    // ...
  }
}
```

As ZIO Schema is not only describing records and enums but also primitive types, tuples, and special cases like `Option` and `Either` and collection types, the deriver has to support all these.

The minimum set of methods to implement is `deriveRecord`, `deriveEnum`, `derivePrimitive`, `deriveOption`, `deriveSequence`, `deriveMap` and `deriveTransformedRecord`. In addition to that we can also override `deriveEither`, `deriveSet` and `deriveTupleN` (1-22) to handle these cases specially.

In case of Desert the `deriveRecord` and `deriveEnum` are calling to the implementation of the same data-evolution aware binary format that was previously implemented using Shapeless, but this time it is automatically supporting Scala 2 and Scala 3 the same time. The `derivePrimitive` is just choosing from predefined `BinaryCodec` instances based on the primitive's type:

```scala
override def derivePrimitive[A](
  st: StandardType[A],
  summoned: => Option[BinaryCodec[A]]
): BinaryCodec[A] =
  st match {
    case StandardType.UnitType           => unitCodec
    case StandardType.StringType         => stringCodec
    case StandardType.BoolType           => booleanCodec
    case StandardType.ByteType           => byteCodec
    // ...
  }
```

Same applies for option, either, sequence etc - it is just a mapping to the library's own definition of these binary codecs.

Under the hood `Deriver` is a macro (implemented separately both for Scala 2 and Scala 3) that traverses the types simultaneously with the provided `Schema` (so it does not need to regenerate those) and maps these informations into calls through the `Deriver` interface. The whole process is initiated by calling the `derive` method on our `Deriver`, which is the entry point of these macros, so it has a different looking (but source-code compatible) definition for Scala 2 and Scala 3:

```scala
// Scala 3
inline def derive[A](implicit schema: Schema[A]): F[A]

// Scala 2
def derive[F[_], A](deriver: Deriver[F])(
  implicit schema: Schema[A]
): F[A] = macro deriveImpl[F, A]
```

These are compatible if you are directly calling them: so you can write

```scala
val binaryCodecDeriver: Deriver[BinaryCodec] = // ...
val pointCodec: BinaryCodec[Point] = binaryCodecDeriver.derive[Point]
```

Or even:

```scala
object BinaryCodecDeriver extends Deriver[BinaryCodec] {
  // ...
}

val pointCodec: BinaryCodec[Point] = BinaryCodecDeriver.derive[Point]
```

But if you want to wrap this derive call you have to be aware that they are macro calls, and they have to be wrapped by (version-specific) macros. This is what Desert is doing - as shown before, it uses the `cached` and `autoAcceptSummoned` modifiers to create a deriver, but still exposes a simple `derive` method through an `object`. To do so it needs to wrap the inner deriver macro with its own macro like this:

```scala
// Scala 2
trait DerivedBinaryCodecVersionSpecific {
  def deriver: Deriver[BinaryCodec]

  def derive[T](implicit schema: Schema[T]): BinaryCodec[T] =
    macro DerivedBinaryCodecVersionSpecific.deriveImpl[T]
}

object DerivedBinaryCodecVersionSpecific {
    def deriveImpl[T: c.WeakTypeTag](
      c: whitebox.Context)(
      schema: c.Expr[Schema[T]]
    ): c.Tree = {
      import c.universe._
      val tpe = weakTypeOf[T]
      q"_root_.zio.schema.Derive.derive[BinaryCodec, $tpe]  (_root_.io.github.vigoo.desert.zioschema.DerivedBinaryCodec.deriver)($schema)"
    }
}

// Scala 3
trait DerivedBinaryCodecVersionSpecific {
  lazy val deriver: Deriver[BinaryCodec]

  inline def derive[T](implicit schema: Schema[T]): BinaryCodec[T] =
    Derive.derive[BinaryCodec, T](DerivedBinaryCodec.deriver)
}
```

## Conclusion

We have a new alternative for deriving type class instances from type information, based on ZIO Schema. You may want to use it if you want to have a single deriver source code for both Scala 2 and Scala 3, if you need more flexibility than what Magnolia provides, or if you are already using ZIO Schema in your project.
