+++
title = "Case Study - Haskell at Prezi"

[taxonomies]
tags = ["haskell", "prezi", "case-study"]
+++

I wrote a *case study* for [FPComplete](http://www.fpcomplete.com) on how we use Haskell at [Prezi](https://prezi.com). It is published [here](https://www.fpcomplete.com/page/case-study-prezi), but I'm just posting it here as well:

[Prezi](https://prezi.com) is a cloud-based presentation and storytelling tool, based on a zoomable canvas. The company was founded in 2009, and today we have more than 50 million users, with more than 160 million prezis created.

The company is using several different platforms and technologies; one of these is *Haskell*, which we are using server side, for code generation and for testing.

## PDOM
Prezi's document format is continuously evolving as we add features to the application. It is very important for us that this format is handled correctly on all our supported platforms, and both on client and server side. To achieve this, we created an eDSL in Haskell that defines the schema of a Prezi. From this schema we are able to generate several artifacts.

Most importantly we are generating a *Prezi Document Object Model (PDOM)* library for multiple platforms - Haxe (compiled to JS) code for the web, C++ code for the native platforms, and Haskell code for our tests, tools and the server side. These libraries are responsible for loading, updating, maintaining consistency and saving Prezis.

This API also implements *collaborative editing* functionality by transparently synchronising document changes between multiple clients. This technique is called [operational transformation (OT)](https://en.wikipedia.org/wiki/Operational_transformation). We implemented the server side of this in Haskell; it supports clients from any of the supported platforms and it is connected to several other backend services.

## Benefits
Using *Haskell* for this project turned out to have huge benefits.

We are taking advantage of Haskell's capabilities to create embedded domain specific languages, using it to define the document's schema in our own eDSL which is used not only by Haskell developers but many others too.

Haskell's clean and terse code allows us to describe document invariants and rules in a very readable way and the type system guarantees that we handle all the necessary cases, providing a stable base Haskell implementation which we can compare the other language backends to.

It was also possible to define a set of merge laws for OT, which are verified whenever we introduce a new element to the document schema, guaranteeing that the collaboration functionality works correctly.

We use the *QuickCheck* testing library on all levels. We can generate arbitrary Prezi documents and test serialization on all the backends. We are even generating arbitrary JavaScript code which uses our generated API to test random collaborative network sessions. These tests turned out to be critical for our success as they caught many interesting problems before we deployed anything to production

