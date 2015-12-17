---
title: Trying out Ceylon - Part 1
tags: ceylon
---
Ceylon's first production release was announced on 12th of November. I decided to try it out after going through the quick introduction, as it looked quite promising. In a series of posts I'd like to share my first attempts to use this interesting language.

This first release came with an eclipse plugin as well - after installing it I was immediately able to start working on my test project. In this few hours the plugin seemed to be stable enough, I did not experience any problems.

I have a `JVLT` file which I created while attending a foreign language course about a year ago. I was using only a limited subset of this application, so basically what I have is a .jvlt file, which is in fact a ZIP archive, in which a `dict.xml` stores a set of words and for each word one or more translation and the lesson we have learnt it.

See the following example:

```xml
<dictionary language="french" version="1.4">
  <entry id="e275">
    <orth>à côté de</orth>
    <sense id="e275-s1">
      <trans>mellett</trans>
    </sense>
    <sense id="e275-s2">
      <trans>mellé</trans>
    </sense>
    <lesson>8</lesson>
  </entry>
</dictionary>
```

My idea was to write an application that helps me learning and practicing these words.

In this first post I'm going to load the dictionary from the JVLT file.

To get started, I created a new Ceylon module with the help of the IDE called jvlt. This immediately created three program units: `module.ceylon`, `package.ceylon` and `run.ceylon`. The `module.ceylon` contains the module definition, which also describes the module's dependencies. As I was trying to implement the dictionary reader, I ended up with the following module definition:

```ceylon
module jvlt "1.0.0" {
    shared import ceylon.file "1.0.0";
	import ceylon.collection "1.0.0";
    import ceylon.interop.java "1.0.0";
 
    import javax.xml "7"; 
 
    import ceylon.test "1.0.0";
}
```

Let's start with the data model we want to build up! The dictionary consists of words:

```ceylon
"Represents a foreign word with one or more senses"
shared class Word(shared String word, shared Set<string> senses, shared Integer lesson){ 
}
```

The word, senses and lessons are all shared attributes of this class, accessible from the outside. To make it easy to access the word objects by their foreign word, I'm currently storing them in a map:

```ceylon
"Represents a dictionary of words in a given language"
shared class Dictionary(shared String language, shared Map<string word=""> words) {
}
```

Basically that's the data model, but I wrapped the whole thing in an abstract JVLT class which looks like this:

```ceylon
"Represents a JVLT file"
abstract shared class JVLT() {
 
	"The dictionary stored in this JVLT"
 	formal shared Dictionary dictionary;
}
```

The idea is that you get a JVLT instance from one of the helper functions and then use it as a root of the data model.

The next thing is to create this data model from the JVLT files. For this, I needed two things:

* Reading a ZIP archive
* Parsing XML

It turned out that Ceylon's file module has ZIP support, with the `createZipFileSystem` function as an entry point. I made two module-level functions beside the JVLT class for creating instances deriving from the abstract JVLT class:

* `loadJVLT` which loads a JVLT ZIP archive from the file system
* `loadJVLTFromDictionaryString` oads directly a dict.xml-like XML passed as a simple string. I'm using this for unit testing the XML parser.

Let's see the ZIP handling first:

```ceylon
"Loads a JVLT file from a `.jvlt` ZIP archive, if possible."
shared JVLT? loadJVLT(File file) {
	value zip = createZipFileSystem(file);
 	value dictPath = zip.parsePath("/dict.xml");
 	if (is File dictFile = dictPath.resource) {  
  		try (reader = dictFile.Reader()) {
   
   			return loadJVLTFromDictionaryString(readAll(reader));
  		}
 	} else {
  		return null;
 	}
}
```

Well, the error handling is not too sophisticated in this case, it either returns a JVLT or returns `null` if the given file did not have a `dict.xml` in it. Other error conditions such as a `dict.xml` with a wrong format, etc., are not handled currently. As you can see, I'm reusing my other load function here, once the `dict.xml` is read.

There are two interesting things here. First, the if statement where we check if the resource is an instance of `File` and immediately store it in the value called `dictFile`. The `dictPath.resource` attribute has the type `Resource` which is a Ceylon interface. It is either an `ExistingResource`: `Directory`, `File` or `Link`, or `Nil`. In any case if it is not a `File` instance, we just return `null`.

For simplicity, I'm reading the full `dict.xml` into a string before parsing it. For this purpose I wrote a small helper function `readAll`:

```ceylon
"Reads all lines from a file reader and returns the concatenated string"
String readAll(File.Reader reader) { 
	variable String result = "";
 
 	while (exists line = reader.readLine()) {
  		result += line; 
 	}
 
 	return result;
}
```

Probably it's not an optimal solution, but works :)

Now that we have our data model and have a way to build it up from XML, we can write some unit tests to see how it works. The Ceylon SDK has a test module and the Ceylon IDE supports running the tests. There is a [separate page in the documentation](http://ceylon-lang.org/documentation/1.0/ide/test-plugin/) describing how. It is really simple, I had to add the test module as a dependency, and I created a separate file to hold my test definitions. The class groups the tests together and optionally supports running extra code before/after each test case, as in other test frameworks:

```ceylon
class DictionaryParserTests() {

	shared test void emptyDictionary() {
	  	value dic = loadJVLTFromDictionaryString("<dictionary>");
	  
	  	assert (dic.dictionary.words.empty);
	  	assert (dic.dictionary.language == "unknown");
	}

 	shared test void languageAttributeRead() {
  		value dic = loadJVLTFromDictionaryString("<dictionary language="testlang">");
  		assert (dic.dictionary.language == "testlang");
 	}

	// ...

```

I won't paste here all the test code, only a few samples to get the feeling how the Ceylon code looks like. To test whether a given word's translations are loaded correctly, I wrote a helper function:

```ceylon
void assertSenses(JVLT jvlt, String w, [String+] expectedSenses) {
  
    Word? word = jvlt.dictionary.words[w];
    if (exists word) {
    	assert (word.senses.equals(HashSet(expectedSenses)));  
    } else {
     	fail("Word does not exists");
    }
}
```

This helper function can be used to assert that a word has been loaded correctly:

```ceylon
shared test void wordWithMultipleSenses() {
	value dic = loadJVLTFromDictionaryString(
  		"<dictionary>
   			<entry id="e1">
    			<orth>src1</orth>
    			<sense id="e1-s1">
     				<trans>dst1</trans>
    			</sense>
    			<sense id="e1-s2">
     				<trans>dst2</trans>
    			</sense>    
   			</entry>  
   		</dictionary>");
 
 	assertSenses(dic, "src1", ["dst1", "dst2"]);
}
```

Now the only problem is that there is no XML parsing support in the Ceylon SDK currently, so it has to be done using Java interop. As I wrote the code to build up the data model from the XML, I wrote several helper functions to make it easier to fit into the language. So let's see first how the dictionary loading is defined, and then I'll show the helper functions.

The XML parsing is done by two module level functions which are not shared - only used by the JVLT constructor functions I shown before. The first one creates a map entry for a single word:

```ceylon
"Creates a word entry for the dictionary"
String->Word loadEntry(Element elem) {
 
 	value w = Word {
  		word = selectNodeText(elem, "orth") else "???";
  		lesson = selectNodeInteger(elem, "lesson") else 0;
  		senses = HashSet(selectNodes(elem, "sense/trans")
  					.map((Node n) => n.textContent));
 	};
 	return w.word->w;
}
```

and the second one loads all the words from the XML document:

```ceylon
"Loads a dictionary from JVLT's `dict.xml` format."
Dictionary loadDictionaryFromXML(Document doc) { 

	doc.documentElement.normalize();

 	return Dictionary { 
  		language = getAttribute(doc.documentElement, "language") else "unknown";
  		words = HashMap({ 
     		for (node in selectNodes(doc, "dictionary/entry"))
       			if (is Element elem = node)
             		loadEntry(elem) });   
 	};
}
```

The function which returns the JVLT instance uses this function and Java interop to read the dictionary:

```ceylon
"Loads a JVLT file by the parsing the dictionary XML directly from a string"
shared JVLT loadJVLTFromDictionaryString(String dictXML) {
	value docBuilderFactory = DocumentBuilderFactory.newInstance();
 	value builder = docBuilderFactory.newDocumentBuilder();
 	value doc = builder.parse(ByteArrayInputStream(javaString(dictXML).bytes));
 
 	object result extends JVLT() { 
  		dictionary = loadDictionaryFromXML(doc);
 	}
 	return result;
}
```

There are two things to notice here: we had to convert from Ceylon's string to Java string. This is not done automatically and we need the `ceylon.interop.java` module to do it. In the last lines we define an anonymous class extending from JVLT and overwriting it's abstract dictionary attribute. Then this anonymous class instance is returned as the loaded JVLT.

To make the XML parsing less painful, I defined a few helper functions in a separate compilation unit (`XmlHelper.ceylon`). I won't show here the full file but there are some interesting parts. First, from Ceylon you cannot call static methods, but you can import them. I'm using the following two import statements: 

```ceylon
import org.w3c.dom { Node, NodeList, Element }
import javax.xml.xpath { XPathFactory { newXPathFactory = newInstance },
       XPathConstants { nodeSet = \iNODESET }}
```

The first one is straightforward. It imports three DOM interfaces. The second one first imports the `XPathFactory.newInstance` static method and also renames it, as newInstance is a too generic name without its class name as a prefix. The third line imports a constant value and gives it a Ceylon-compatible name. Because in Ceylon only the types can start with an uppercase character, we have to use a special and ugly syntax which helps the interoperability - prefixing it with `\i`.

The `ceylon.interop.java` module has helper classes to make Java Iterable objects iterable in Ceylon, but unfortunately the `NodeList` interface is not iterable in Java either. So I wrote a simple wrapper that iterates through a node list:

```ceylon
class NodeListIterator(NodeList nodes) satisfies Iterable<Node> {
	shared actual default Iterator<Node> iterator() {
  		object it satisfies Iterator<Node> {   
   			variable Integer i = 0;
   
   			shared actual Node|Finished next() {
    			if (i < nodes.length) {
     				return nodes.item(i++);
    			} else {
     				return finished;
    			}
   			}
  		}
  		return it;
 	}
}
```

Using this iterator and the imports I wrote a `selectNodes` function to run XPath expressions and return the result as a Ceylon iterable:

```ceylon
{Node*} selectNodes(Node root, String xpath) { 
	value factory = newXPathFactory();
 	value xpathCompiler = factory.newXPath();
 	value expr = xpathCompiler.compile(xpath);
 	value nodeList = expr.evaluate(root, nodeSet); 
 	if (is NodeList nodeList) {  
  		return NodeListIterator(nodeList);
 	}
 	else {
  		return [];
 	}
}
```

Using this function it is very easy to write a variant that selects a single node:

```ceylon
Node? selectNode(Node root, String xpath) { 
	return selectNodes(root, xpath).first;
}
```

There are some other helper functions returning the node's text, converting it to integer, etc. but I think they are not that interesting. Now that I have my data model which is built from my JVLT file, the next thing is to make a user interface somehow where the vocabulary can be shown an the user's knowledge can be tested/improved. This will be the topic of some future posts, as soon as I have time to experiment more with this new language.


