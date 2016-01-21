---
title: Haskell plugin for Gradle
tags: haskell gradle build tools
---

My team at [Prezi](https://prezi.com) uses **Haskell** for several projects, which usually depend on each other, often with build steps using other languages such as Scala, C++ or Haxe. As [Gradle](https://gradle.org/) is used heavily in the company, we decided to try to integrate our Haskell projects within Gradle.

The result is [Gradle Haskell Plugin](https://github.com/prezi/gradle-haskell-plugin), which we were using succesfully in the last 2 months in our daily work, and we have *open-sourced* recently.

What makes this solution interesting is that it not just simply wraps *cabal* within Gradle tasks, but implements a way to define **dependencies** between Haskell projects and to upload the binary Haskell artifacts to a *repository* such as [artifactory](http://www.jfrog.com/open-source/). 

This makes it easy to modularize our projects, publish them, and also works perfectly with [pride](https://github.com/prezi/pride), an other *open-source* Prezi project. This means that we can work on a subset of our Haskell projects while the other dependencies are built on Jenkins, and it also integrates well with our non-Haskell projects.

## How does it work?

The main idea is that we let _cabal_ manage the Haskell packages, and handle whole Haskell _sandboxes_ on Gradle level. So if you have a single Haskell project, it will be built using _cabal_ and the result sandbox (the built project together with all the dependent cabal packages which are not installed in the _global package database_) will be packed/published as a Gradle _artifact_.

This is not very interesting so far, but when you introduce dependencies on Gradle level, the plugin does something which (as far as I know) is not really done by anyone else, which I call _sandbox chaining_. This basically means that to compile the haskell project, the plugin will pass all the dependent sandboxes' package database to cabal and GHC, so for the actual sandbox only the packages which are **not** in any of the dependent sandboxes will be installed.

## Example

Let's see an example scenario with _4 gradle-haskell projects_.

<a href="https://raw.githubusercontent.com/prezi/gradle-haskell-plugin/master/doc/gradle-haskell-plugin-drawing1.png" class="zimg"><img width="600" src="https://raw.githubusercontent.com/prezi/gradle-haskell-plugin/master/doc/gradle-haskell-plugin-drawing1.png" alt="gradle-haskell-plugin"></a>

The project called _Haskell project_ depends on two other projects, which taking into accound the transitive dependencies means it depends on _three other haskell projects_. Each project has its own haskell source and _cabal file_. Building this suite consists of the following steps:

- **dependency 1** is built using only the _global package database_, everything **not** in that database, together with the compiled project goes into its `build/sandbox` directory, which is a combination of a _GHC package database_ and the project's build output. This is packed as **dependency 1**'s build artifact.
- For **dependency 2**, Gradle first downloads the build artifact of _dependency 1_ and extracts it to `build/deps/dependency1`. 
- Then it runs [SandFix](https://github.com/exFalso/sandfix) on it
- And compiles the second project, now passing **both** the _global package database_ and **dependency 1**'s sandbox to cabal/ghc. The result is that only the packages which are **not** in any of these two package databases will be installed in the project's own sandbox, which becomes the build artifact of **dependency 2**.
- For **dependency 3**, Gradle extracts both the direct dependency and the transitive dependency's sandbox, to `build/deps/dependency2` and `build/deps/dependency3`.
- Then it runs [SandFix](https://github.com/exFalso/sandfix) on both the dependencies
- And finally passes three package databases to cabal/ghc to compile the project. Only those cabal dependencies will be installed into this sandbox which are not in global, neither in any of the dependent sandboxes.
- Finally, for **Haskell project** it goes the same way, but here we have three sandboxes, all chained together to make sure only the built sandbox only contains what is not in the dependent sandboxes yet.

For more information, check out [the documentation](https://github.com/prezi/gradle-haskell-plugin).
