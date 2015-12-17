---
title: Cloning WPF flow document fragments
tags: .net, c#
---
Today I had to write such an ugly hack to fix a bug that I decided to start writing a blog where I can show it to the world :)

The software I'm working on has some sort of context sensitive help panel, which is implemented using dynamically generated [flow documents](http://msdn.microsoft.com/en-us/library/aa970909.aspx). The software loads a large set of flow document sections from a XAML file runtime, and later builds documents from a subset of them.

For some reason (which belong to a separate post), it is not possible to reuse these flow document elements in multiple flow documents, not even if there is only one at a time. To work around this, I was cloning these sections before adding them to the document.

As WPF elements are not _cloneable_, I was using the method recommended many places, for example [in this StackOverflow post](http://stackoverflow.com/questions/32541/how-can-you-clone-a-wpf-object): saving the object tree to an in-memory XAML stream, and loading it back.

This worked quite well.. until we discovered a bug, which I still cannot explain. In some cases which were easily reproducible for any developer, but the code running in those cases being exactly the same as in other, working cases, the clone method simply stopped working.

Stopped working here means that the following code:

```cs
var xaml = XamlWriter.Save(block);
```

would write out the correct object hierarchy, but without any properties (no attributes, no content properties, nothing but the element names)! In the same time the objects in the memory were untouched and still had all the relevant properties set.

I also tried to write my own XAML serializer based on the code found [at this site](http://go4answers.webhost4life.com/Example/xaml-serialization-replacement-75133.aspx), but this was only good to find out that the problem lies deep within the `MarkupWriter` class, which is the same what the `XamlWriter` uses internally. When the `XamlWriter` failed, my own code could not find any properties using the returned [MarkupObject](http://msdn.microsoft.com/en-us/library/system.windows.markup.primitives.markupobject.aspx):

```cs
MarkupObject markupObj = MarkupWriter.GetMarkupObjectFor(obj);
```

For the same object, in the working scenarios it returned a markup object with a working `Properties` collection.

So here is the final _"solution"_ which I'm not really proud of, but solved the problem. Maybe with some modifications it is useful for someone struggling with the framework:

```cs
/// <summary>
/// Horrible ugly clone hack to issues where XamlWriter/XamlReader based
/// clone method did not work.
/// </summary>
public static class CloneHelper
{
    public static Block Clone<t>(this T block)
        where T : Block
    {
        var result = (T)DeepClone(block);

        return result;
    }

    private static object DeepClone(object obj)
    {
        if (obj != null)
        {
            // Replacing ResourceDictionary and Style values with null. 
            // In this particular use case it is correct to do
            if (obj.GetType() == typeof(ResourceDictionary) ||
                obj.GetType() == typeof(Style))
            {
                return null;
            }
            else
            {
                // Value types and some special cases where we don't want to clone
                if (obj.GetType().IsValueType ||
                    obj.GetType() == typeof (Cursor) ||
                    obj.GetType() == typeof (XmlLanguage))
                {
                    return obj;
                }
                else
                {
                    // If it is cloneable, use it
                    var cloneable = obj as ICloneable;
                    if (cloneable != null)
                    {
                        return cloneable.Clone();
                    }
                    else
                    {
                        // Creating the clone with reflection
                        var typ = obj.GetType();
                        var clone = Activator.CreateInstance(typ);                     

                        // Property names which are known locally set 
                        // dependency properties
                        var usedNames = new HashSet<string>();                        

                        // Copying locally set dependency properties from the 
                        // source to the target
                        var dobjSource = obj as DependencyObject;
                        var dobjTarget = clone as DependencyObject;
                        if (dobjSource != null && dobjTarget != null)
                        {
                            var locallySetProperties = 
                                dobjSource.GetLocalValueEnumerator();
                            while (locallySetProperties.MoveNext())
                            {
                                DependencyProperty dp = 
                                    locallySetProperties.Current.Property;
                                if (!dp.ReadOnly)
                                {
                                    dobjTarget.SetValue(dp, dobjSource.GetValue(dp));
                                    usedNames.Add(dp.Name);
                                }
                            }
                        }                        

                        // Getting all the public, non-static properties of the source
                        foreach (var pi in typ.GetProperties(
                                            BindingFlags.Instance | 
                                            BindingFlags.Public | 
                                            BindingFlags.FlattenHierarchy))
                        {
                            // If it is not a dependency property 
                            // and not the default property...
                            if (pi.CanRead &&
                                !usedNames.Contains(pi.Name) &&
                                !IsDependencyProperty(dobjSource, pi) &&
                                pi.Name != "Item")
                            {                                    
                                var val = pi.GetValue(obj, null);

                                // ..and it is writeable, then we recursively clone 
                                // the value and set the property:
                                if (pi.CanWrite)
                                {                                        
                                    pi.SetValue(clone, DeepClone(val), null);
                                }
                                else
                                {
                                    // ..otherwise if it is a readonly list property, 
                                    // go through each item,  clone it and add to 
                                    // the clone's list property
                                    if (pi.PropertyType
                                          .GetInterfaces()
                                          .Contains(typeof (IList)))
                                    {
                                        var source = val as IList;
                                        var target = pi.GetValue(clone, null) as IList;

                                        if (source != null && target != null)
                                        {
                                            foreach (var item in source)
                                                target.Add(DeepClone(item));
                                        }
                                    }
                                }
                            }
                        }                        

                        return clone;
                    }
                }
            }
        }
        else
        {
            return null;
        }
    }    

    /// <summary>
    /// Tries to determine if a property is a dependency property, by reflection and 
    /// naming convention
    /// </summary>
    /// <param name="dobj">Dependency object
    /// <param name="pi">Property info
    /// <returns>Returns <c>true</c> if the given property seems to be a 
    ///          CLR access property for a dependency property.</returns>
    private static bool IsDependencyProperty(DependencyObject dobj, PropertyInfo pi)
    {
        if (dobj != null)
        {
            var dpProp = dobj.GetType().GetProperty(pi.Name + "Property", 
                                                    BindingFlags.Static |
                                                    BindingFlags.Public |
                                                    BindingFlags.FlattenHierarchy);
            if (dpProp != null && dpProp.PropertyType == typeof (DependencyProperty))
                return true;
            else
            {
                var dpField = dobj.GetType().GetField(pi.Name + "Property", 
                                                      BindingFlags.Static | 
                                                      BindingFlags.Public | 
                                                      BindingFlags.FlattenHierarchy);
                if (dpField != null && 
                    dpField.FieldType == typeof (DependencyProperty) && 
                    dpField.IsInitOnly && dpField.IsStatic)
                    return true;
            }
        }        

        return false;
    }
}
```
