+++
title = "Zig and the WASM Component Model"

[taxonomies]
tags = ["zig", "wasm", "golem"]
+++

[Golem](https://golem.cloud) always considered [Zig](https://ziglang.org) a supported language, but until now the only documented way to use it was to compile a program with a single `main` function into a *core WebAssembly module* and then wrap that as a component that can be uploaded to Golem for execution. This is very limiting, as in order to take full advantage of Golem (and any other part of the evolving *WASM Component Model ecosystem*) a Zig program must have definitions for both _importing_ and _exporting_ functions and data types in order to be a usable component. 

## Binding generators

For many supported languages the workflow is to write a **WIT** file, which is the Component Model's [interface definition language](https://component-model.bytecodealliance.org/design/wit.html) and then use a _binding generator_, such as [wit-bindgen](https://github.com/bytecodealliance/wit-bindgen/) to create statically typed representation of the component's imports and exports in the targeted language. 

The binding generator does not support Zig, but it does support C. So the best we can do with existing tooling is to use the C binding generator and Zig's excellent C interoperability together to be able to create WASM components with Zig.

## The steps

The primary steps are the following:

- **Define** the component's interface using WIT
- **Generate** C bindings from this definition
- **Implement** the exported functions in Zig, potentially using other imported interfaces and data types available through the generated binding
- **Compile** the whole project into WASM
- As Zig's standard library still uses *WASI Preview 1*, and outputs a single WASM module, we also have to **compose** our resulting module with an *adapter component* in order to get a WASM component depending on _WASI Preview 2_.

The first step is manual work - although we may eventually get code-first approaches in some languages where the WIT interface is generated as part as the build flow, it is not the case for Zig at the moment.

For generating the bindings we use `wit-bindgen`, and once the implementation is done we compile the Zig source code, together with the generated C bindings into a WASM module using zig's build system (`zig build`). 

Finally we can use `wasm-tools compose` to take this WASM module and an appropriate version of a Preview1 adapter such as [the one we provide for Golem](https://github.com/golemcloud/golem-wit/blob/main/adapters/tier1/wasi_snapshot_preview1.wasm) to get the final component that's ready to be used with Golem.

## Zig's build system

Executing all these steps manually is not convenient but fortunately we can integrate all the steps within Zig's _build system_. Let's see how!

We need to write a custom `build.zig` in the following way. First, let's do some imports and start defining our build flow:

```zig
const std = @import("std");
const Builder = std.build.Builder;
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Builder) !void {
```

The first non-manual thing on our list of steps is **generating** the C bindings. Let's define a build step that just runs `wit-bindgen` for us:

```zig
    const bindgen = b.addSystemCommand(&.{ "wit-bindgen", "c", "--autodrop-borrows", "yes", 
    	"./wit", "--out-dir", "src/bindings" });
```

This is just a description of running the binding generator, not integrated within the build flow yet. The next step is **compiling** our Zig and C files into WASM. 

First we define it as an _executable target_:

```zig
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });
    const wasm = b.addExecutable(.{ 
    	.name = "main",
      .root_source_file = .{ .path = "src/main.zig" }, 
      .target = .{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    	}, 
    	.optimize = optimize 
    });
```

This already defines we want to use WASM and target WASI and points to our root source file. We are not done yet though, as if we run the binding generator step defined above, we will end up having a couple of files generated in our `src/bindings` directory:

```
λ l src/bindings
.rw-r--r-- 909 vigoo  9 May 09:34 zig3.c
.rw-r--r-- 371 vigoo  9 May 09:34 zig3.h
.rw-r--r-- 299 vigoo  9 May 09:34 zig3_component_type.o
```

The `.c`/`.h` pair contains the generated binding, while the object file holds the binary representation of the WIT interface it was generated from.

We need to add the C source and the object file into our build, and the header file to the include file paths. As the name of the generated files depend on the WIT file's contents, we need to list all files in this `bindings` directory and mutate our `wasm` build target according to what we find:

```zig
    const binding_root = b.pathFromRoot("src/bindings");
    var binding_root_dir = try std.fs.cwd().openIterableDir(binding_root, .{});
    defer binding_root_dir.close();
    var it = try binding_root_dir.walk(b.allocator);
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const path = b.pathJoin(&.{ binding_root, entry.path });
                if (std.mem.endsWith(u8, entry.basename, ".c")) {
                    wasm.addCSourceFile(.{ .file = .{ .path = path }, .flags = &.{} });
                } else if (std.mem.endsWith(u8, entry.basename, ".o")) {
                    wasm.addObjectFile(.{ .path = path });
                }
            },
            else => continue,
        }
    }
```

This registers all the `.c` and `.o` files from the generated bindings, but we still need to add the whole directory as an include path:

```zig
    wasm.addIncludePath(.{ .path = binding_root });
```

and enable linking with `libc`:

```zig
    wasm.linkLibC();
```

Now that we defined two build steps - the generating the bindings and compiling to a WASM module - we define the third step which is **composing** the generated module and the preview1 adapter into a WASM component:

```zig
    const adapter = b.option(
    	[]const u8, 
    	"adapter", 
    	"Path to the Golem Tier1 WASI adapter") orelse "adapters/tier1/wasi_snapshot_preview1.wasm";
    const out = try std.fmt.allocPrint(b.allocator, "zig-out/bin/{s}", .{wasm.out_filename});
    const component = b.addSystemCommand(&.{ "wasm-tools", "component", "new", out, 
    	"-o", "zig-out/bin/component.wasm", "--adapt", adapter });
```

Here we provide a way to override the path to the adapter WASM using `zig build -Dadapter=xxx` but default to `adapters/tier1/wasi_snapshot_preview1.wasm` in case it is not specified.

The final step is to set up dependencies between these build steps and wire them to the main build flow:

```zig
    wasm.step.dependOn(&bindgen.step);
    component.step.dependOn(&wasm.step);
    b.installArtifact(wasm);
    b.getInstallStep().dependOn(&component.step);
  }
```

## Trying it out

Let's try this out by implementing a simple counter component. We start with the first step - defining our WIT file, putting it into `wit/counter.wit`:

```wit
package golem:example;

interface api {
  add: func(value: u64);
  get: func() -> u64;
}

world counter {
  export api;
}

```

We also save the above defined build script as `build.zig` (full version [available here](https://gist.github.com/vigoo/19ed4b5d3e47ca2f5f1258d1ae8b28a4)) and then write an initial  `src/main.zig` file:

```zig
const std = @import("std");

pub fn main() anyerror!void {}
```

Let's place the [adapter WASM](https://github.com/golemcloud/golem-wit/raw/main/adapters/tier1/wasi_snapshot_preview1.wasm) as well in the `adapters/tier1` directory, and then try to compile this:

```
λ zig build --summary all                                                                                 ...
zig build-exe main Debug wasm32-wasi: error: the following command failed with 2 compilation errors:
...
error: wasm-ld: /Users/vigoo/projects/demo/counter/zig-cache/o/a212123ad3dcf4839747c2bd77f7ef4e/counter.o:
undefined symbol: exports_golem_example_api_add
error: wasm-ld: /Users/vigoo/projects/demo/counter/zig-cache/o/a212123ad3dcf4839747c2bd77f7ef4e/counter.o:
undefined symbol: exports_golem_example_api_get
```

It fails because we defined two exported functions: `api/add` and `api/get` in our WIT file but haven't implemented them yet. Let's do that:

```zig
var state: u64 = 0;

export fn exports_golem_example_api_add(value: u64) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("Adding {} to state\n", .{value}) catch unreachable;
    state += value;
}

export fn exports_golem_example_api_get() u64 {
    return state;
}
```

Then compile it:

```
λ zig build --summary all
Generating "src/bindings/counter.c"
Generating "src/bindings/counter.h"
Generating "src/bindings/counter_component_type.o"
Build Summary: 5/5 steps succeeded
install success
├─ install main cached
│  └─ zig build-exe main Debug wasm32-wasi cached 9ms MaxRSS:29M
│     └─ run wit-bindgen success 3ms MaxRSS:3M
└─ run wasm-tools success 11ms MaxRSS:8M
   └─ zig build-exe main Debug wasm32-wasi (+1 more reused dependencies)
```

and we can verify our resulting `zig-out/component.wasm` using `wasm-tools`:

```
λ wasm-tools print --skeleton zig-out/bin/component.wasm 
(component
  ...
  (instance (;11;) (instantiate 0
      (with "import-func-add" (func 16))
      (with "import-func-get" (func 17))
    )
  )
  (export (;12;) "golem:example/api" (instance 11))
  (@producers
    (processed-by "wit-component" "0.20.1")
  )
)
```

## Using imports

After this simple example let's try _importing_ some interface and using that from our Zig code. What we are going to do is every time our counter changes, we are going to also save that value to an external key-value store. This is usually not something you need to do when writing a Golem application, because your program will be durable anyway - you can just keep the counter in memory. But it is a simple enough example to demonstrate how to use imported interfaces from Zig.

First let's add some additional WIT files into `wit/deps` from the [golem-wit repository](https://github.com/golemcloud/golem-wit) (Note that the WASI Key-Value interface is defined [here](https://github.com/WebAssembly/wasi-keyvalue), the `golem-wit` repo just stores the exact version of its definitions which is currently implemented by Golem ).

We need the following directory tree:

```
λ tree wit
wit
├── counter.wit
└── deps
    ├── io
    │   ├── error.wit
    │   ├── poll.wit
    │   ├── streams.wit
    │   └── world.wit
    └── keyvalue
        ├── atomic.wit
        ├── caching.wit
        ├── error.wit
        ├── eventual-batch.wit
        ├── eventual.wit
        ├── handle-watch.wit
        ├── types.wit
        └── world.wit

4 directories, 13 files
```

Then we can import the key-value interface to `counter.wit`:

```wit
package golem:example;

interface api {
  add: func(value: u64);
  get: func() -> u64;
}

world counter {
  import wasi:keyvalue/eventual@0.1.0;

  export api;
}
```

By recompiling the project we can verify everything still works, and we will also get our new bindings generated in the C source.

Before implementing writing to the key-value store in Zig, let's just take a look at the WIT interface of `wasi:keyvalue/eventual@0.1.0` to understand what we will have to do:

```wit
interface eventual {
  // ...
  set: func(
    bucket: borrow<bucket>, 
    key: key, 
    outgoing-value: borrow<outgoing-value>
  ) -> result<_, error>;
}
```

We will need to pass a `bucket` and an `outgoing-value`, both being _WIT resources_ so we first need to create them, then borrow references of them for the `set` call, and finally drop them.

The bucket resource can be constructed with a static function called `open-bucket`:

```wit
resource bucket {
  open-bucket: static func(name: string) -> result<bucket, error>;
}
```

Searching for this in the generated C bindings reveals the following:

```c
extern bool wasi_keyvalue_types_static_bucket_open_bucket(
  counter_string_t *name, 
  wasi_keyvalue_types_own_bucket_t *ret, 
  wasi_keyvalue_types_own_error_t *err
);
```

We will have to drop the created bucket with

```c
extern void wasi_keyvalue_types_bucket_drop_own(
  wasi_keyvalue_types_own_bucket_t handle
);
```

With all this information let's try to open a bucket in Zig by directly using the generated C bindings. First we need to import the C headers:

```zig
const c = @cImport({
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("counter.h");
});
```

We also define an initial error type for our function for using later:

```zig
const KVError = error {
    FailedToOpenBucket,
};
```

Then start implementing the store function by first storing the bucket's name in `counter_string_t`:

```zig
fn record_state() anyerror!void {
    const stdout = std.io.getStdOut().writer();

    var bucket_name: c.counter_string_t = undefined;
    c.counter_string_dup(&bucket_name, "state");
    defer c.counter_string_free(&bucket_name);
```

and then invoking the `wasi_keyvalue_types_static_bucket_open_bucket` function:

```zig
    var bucket: c.wasi_keyvalue_types_own_bucket_t = undefined;
    var bucket_err: c.wasi_keyvalue_wasi_keyvalue_error_own_error_t = undefined;
    if (c.wasi_keyvalue_types_static_bucket_open_bucket(&bucket_name, &bucket, &bucket_err)) {
        defer c.wasi_keyvalue_types_bucket_drop_own(bucket);
        
        // TODO
    } else {
        defer c.wasi_keyvalue_wasi_keyvalue_error_error_drop_own(bucket_err);
        try stdout.print("Failed to open bucket\n", .{});

        return KVError.FailedToOpenBucket;
    }
}
```

Now that we have an open bucket we want to call the `set` function to update a key's value:

```c
extern bool wasi_keyvalue_eventual_set(
  wasi_keyvalue_eventual_borrow_bucket_t bucket, 
  wasi_keyvalue_eventual_key_t *key, 
  wasi_keyvalue_eventual_borrow_outgoing_value_t outgoing_value, 
  wasi_keyvalue_eventual_own_error_t *err
);
```

We already have our bucket, but we _own_ it and we need to pass a _borrowed_ bucket to this function. What's the difference? There is no difference in the actual value - both just store a _handle_ to a resource that exists in the runtime engine, but we still have to borrow the owned value using the `wasi_keyvalue_types_borrow_bucket` function. The `wasi_keyvalue_eventual_key_t` type is just an alias for `counter_string_t` and `wasi_keyvalue_eventual_borrow_outgoing_value_t` is another resource we need to construct first. Let's put this together!

First we borrow the owned bucket:

```zig
var borrowed_bucket = c.wasi_keyvalue_types_borrow_bucket(bucket);
defer c.wasi_keyvalue_types_bucket_drop_borrow(borrowed_bucket);
```

Then we create an _outgoing value_ that's going to be stored in the key-value store:

```zig
var outgoing_value = c.wasi_keyvalue_types_static_outgoing_value_new_outgoing_value();
defer c.wasi_keyvalue_types_outgoing_value_drop_own(outgoing_value);
var borrowed_outgoing_value = c.wasi_keyvalue_types_borrow_outgoing_value(outgoing_value);
defer c.wasi_keyvalue_types_outgoing_value_drop_borrow(borrowed_outgoing_value);
        
var body: c.counter_string_t = undefined;
var value = try std.fmt.allocPrint(gpa.allocator(), "{d}", .{state});
c.counter_string_set(&body, @ptrCast(value));
defer c.counter_string_free(&body);

var write_err: c.wasi_keyvalue_types_own_error_t = undefined;
if (!c.wasi_keyvalue_types_method_outgoing_value_outgoing_value_write_body_sync(
    borrowed_outgoing_value, 
    @ptrCast(&body),
    &bucket_err)) {
        
    defer c.wasi_keyvalue_wasi_keyvalue_error_error_drop_own(write_err);
    try stdout.print("Failed to set outgoing value\n", .{});
    return KVError.FailedToSetKey;
}
```

Also we need to create a string for holding the _key_:

```zig
var key: c.counter_string_t = undefined;
c.counter_string_dup(&key, "latest");
defer c.counter_string_free(&key);
```

And finally call the `set` function:

```zig
var set_err: c.wasi_keyvalue_eventual_own_error_t = undefined;
if (!c.wasi_keyvalue_eventual_set(borrowed_bucket, &key, borrowed_outgoing_value, &set_err)) {
    try stdout.print("Failed to set key\n", .{});
    return KVError.FailedToSetKey;
}
```

With this implementation we can compile our new version of our WASM component which now also depends on `wasi:keyvalue` and stores the latest value in a remote storage every time it gets updated.

## What's next?

With the above technique we have a way to impelment WASM components in Zig, but working with the generated C bindings is a bit inconvenient. It would be nice to have a more idiomatic Zig interface to the component model, and maybe it can be achieved just by using Zig's metaprogramming features without having to create a Zig specific binding generator in addition to the existing ones.
