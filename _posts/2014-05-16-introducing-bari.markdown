---
layout: post
title: Introducing bari
tags: dotnet bari build tools
---
In the past two years I worked on a project called
[bari](https://github.com/vigoo/bari) which now reached an usable
state. **bari** is a *build management system*, trying to fix Visual
Studio's bad parts while keeping the good ones.

Basically it tries to make .NET development more convenient, when

* The application may consist of a *large number of projects*
* There may be several different *subsets* of these projects defining
  valuable target *products*
* *Custom build steps* may be required
* It is important to be able to *reproduce* the build environment as
    easily as possible
* The developers want to use the full power of their *IDE*

The main idea is to generate Visual Studio solutions and projects *on
the fly* as needed, from a conceise *declarative*  build
description. I tried to optimize this build description for human
readability. Let's see an example, a short section from **bari**'s own
build definition:

{% highlight yaml %}
- name: bari
  type: executable
  references:
    - gac://System
    - nuget://log4net
    - nuget://Ninject/3.0.1.10
    - nuget://QuickGraph
    - module://Bari.Core
  csharp:
    root-namespace: Bari.Console
{% endhighlight %}

The main advantage of generating solutions and projects on the fly is that each developer can work on the subset he needs for his current task keeping the IDE fast, but can also open everything in one solution if it is useful for performing a refactoring. 

To keep build definitions short and readable, **bari** prefers
*convention* over *configuration*. For example the directory stucture
in which the source code lays defines not only the name of the modules
to build, but also the way it is built. For example, in a simple
_hello world_ example the C# source code would be put in the
`src/TestModule/HelloWorld/cs` directory, and **bari** would build
`target/TestModule/HelloWorld.exe`.

**bari** unifies the handling of *project references* in a way that referencing projects within a suite, from the GAC, using [Nuget](http://www.nuget.org) or from a custom repository works exactly the same. It is also possible to write *custom builders* in Python. 

For more information check out [the getting started page](https://github.com/vigoo/bari/wiki/GettingStarted).
