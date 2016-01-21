---
title: Gradle-Haskell-plugin with experimental Stack support
tags: haskell gradle build tools
---

I've released a **new version (0.4)** of [gradle-haskell-plugin](https://github.com/prezi/gradle-haskell-plugin) today, with **experimental stack support**.
It is not enabled by default, but I used it exclusively for months and it seems to get quite stable. To use it you need [stack](https://haskellstack.com),
have it enabled with `-Puse-stack` and have to keep some rules in your `.cabal` file, as explained [in the README](https://github.com/prezi/gradle-haskell-plugin#explanation-stack-mode).

## How does it work?
The core idea did not change [compared to the original, cabal based solution](http://vigoo.github.io/posts/2015-04-22-gradle-haskell-plugin.html).

To support chaining the binary artifacts, I had to add a new option to *stack* called [extra package databases](https://github.com/commercialhaskell/stack/pull/990). The databases listed in this section are passed *after the global* but **before** the snapshot and the local databases, which means that the snapshot database cannot be used (the packages in the binary artifacts are not "seeing" them). This sounds bad, but *gradle-haskell-plugin* does a workaround; it **generates** the `stack.yaml` automatically, and in a way that:

- it disables snapshots on stack level (uses a resolver like `ghc-7.10.2`)
- lists all the dependencies explicitly in `extra-deps`
- but it still figures out the *versions* of the dependencies (to be listed in `extra-deps`) based on a given *stackage snapshot*!

With this approach we get the same behavior that was already proven in cabal mode, but with the advantage that the generated `stack.yaml` completely defines the project for any tool that knows stack. So after gradle extracted the dependencies and generated the `stack.yaml`, it is no longer needed to succesfully compile/run/test the project, which means that tools like IDE integration will work much better than with the more hacky cabal mode of the plugin.

