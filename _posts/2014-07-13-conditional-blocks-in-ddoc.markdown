---
layout: post
title: Conditional blocks in Distributed Documentor
tags: ddoc
---
I've added a new feature to [Distributed Documentor](https://github.com/vigoo/distributed-documentor) today, *conditional blocks*.

The idea is that parts of the documents can be enabled when a given *condition* is present. This is very similar to [C's ifdef blocks](http://gcc.gnu.org/onlinedocs/cpp/Ifdef.html). To use it with the *MediaWiki syntax*, put `[When:X]` and `[End]` commands in separate lines:

    Unconditional

    [When:FIRST]
    First conditional

    [When:SECOND]
    First and second conditional
    [End]
    [End]

    [When:SECOND]
    Second conditional
    [End]

*Snippets* can also have conditional blocks.

There are two possibilities to set which conditionals are enabled:

1. Specifying it with command line arguments, such as

        java -jar DistributedDocumentor.jar -D FIRST -D SECOND

    This is useful when exporting a documentation from command line, or to launch the documentation editor with a predefined set of enabled conditions.

2. On the user interface, using *View* menu's *Enabled conditions...* menu item:

![unit-conversion-shot](/assets/images/enabled-conditions-dialog.png)
