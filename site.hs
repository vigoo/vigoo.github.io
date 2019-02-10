--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
import           Data.Monoid (mappend)
import qualified Data.Set as Set
import qualified GHC.IO.Encoding as E
import           Hakyll
import           Text.Pandoc.Extensions
import           Text.Pandoc.Highlighting
import           Text.Pandoc.Options


main :: IO ()
main = do
    E.setLocaleEncoding E.utf8
    site

site :: IO ()
site = hakyll $ do
    match "js/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "images/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    match "posts/*" $ do
        route $ setExtension "html"
        let readerOpts = 
              defaultHakyllReaderOptions 
                { readerExtensions = (readerExtensions defaultHakyllReaderOptions) <> githubMarkdownExtensions
                }
        let writerOpts = 
              defaultHakyllWriterOptions
                { writerHighlightStyle = Just pygments
                }
        compile $ pandocCompilerWith readerOpts writerOpts
            >>= loadAndApplyTemplate "templates/post.html"    postCtx
            >>= saveSnapshot "content"
            >>= loadAndApplyTemplate "templates/disqus.html"  postCtx
            >>= loadAndApplyTemplate "templates/default.html" postCtx
            >>= relativizeUrls

    create ["archive.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let archiveCtx =
                    listField "posts" postCtx (return posts) `mappend`
                    constField "title" "Archives"            `mappend`
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" archiveCtx
                >>= relativizeUrls


    match "index.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let indexCtx =
                    listField "posts" postCtx (return posts) `mappend`
                    constField "title" "vigoo's software development blog" `mappend`
                    defaultContext

            getResourceBody
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/default.html" indexCtx
                >>= relativizeUrls

    match "templates/*" $ compile templateCompiler
    
    create ["atom.xml"] $ do
        route idRoute
        compile $ do
            let feedCtx = postCtx `mappend` bodyField "description"
            posts <- fmap (take 50) . recentFirst =<<
                loadAllSnapshots "posts/*" "content"
            renderAtom feedConfig feedCtx posts


feedConfig :: FeedConfiguration
feedConfig = FeedConfiguration
    { feedTitle       = "vigoo's software development blog"
    , feedDescription = "vigoo's software development blog"
    , feedAuthorName  = "Daniel Vigovszky"
    , feedAuthorEmail = "daniel.vigovszky@gmail.com"
    , feedRoot        = "http://vigoo.github.io"
    }

--------------------------------------------------------------------------------
postCtx :: Context String
postCtx =
    dateField "date" "%B %e, %Y" `mappend`
    defaultContext
