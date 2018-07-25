-- | This module exposes a component that can be used to build accessible selection
-- | user interfaces. You are responsible for providing all rendering, with the help
-- | of the `Select.Utils.Setters` module, but this component provides the relevant
-- | behaviors for dropdowns, autocompletes, typeaheads, keyboard-navigable calendars,
-- | and other selection UIs.
module Select where

import Prelude

import Control.Comonad (extract)
import Control.Comonad.Store (Store, store)
import Control.Monad.Free (Free, foldFree, liftF)
import Data.Array (length, (!!))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for_, traverse_)
import Effect.Aff (Fiber, delay, error, forkAff, killFiber)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.Query.ChildQuery as CQ
import Renderless.State (getState, modifyState_, modifyStore)
import Web.Event.Event (preventDefault, currentTarget, Event)
import Web.HTML.HTMLElement (HTMLElement, blur, focus, fromEventTarget)
import Web.UIEvent.KeyboardEvent as KE
import Web.UIEvent.MouseEvent as ME

----------
-- Component Types

-- | A useful shorthand for the Halogen component type
type Component pq cs item m
  = H.Component HH.HTML (Query pq cs item m) (Input pq cs item m) (Message pq item) m

-- | A useful shorthand for the Halogen component HTML type
type HTML pq cs item m
  = H.ComponentHTML (Query pq cs item m) cs m

-- | A useful shorthand for the Halogen component DSL type
type DSL pq cs item m
  = H.HalogenM (StateStore pq cs item m) (Query pq cs item m) cs (Message pq item) m

-- | The component's state type, wrapped in `Store`. The state and result of the
-- | render function are stored so that `extract` from `Control.Comonad` can be
-- | used to pull out the render function.
type StateStore pq cs item m
  = Store (State item) (HTML pq cs item m)

-- | A useful shorthand for the Halogen component slot type
type Slot pq cs item m = H.Slot (Query pq cs item m) (Message pq item)

----------
-- Core Constructors

-- | These queries ensure the component behaves as expected so long as you use the
-- | helper functions from `Select.Setters` to attach them to the right elements.
-- |
-- | - `pq`: The query type of the component that will mount this component in a child slot.
-- |         This allows you to embed your own queries into the `Select` component.
-- | - `cs`: The slot type of potential child components you might want to embed in the `Select`
-- |         component
-- | - `item`: Your custom item type. It can be a simple type like `String`, or something
-- |           complex like `CalendarItem StartDate EndDate (Maybe Disabled)`.
-- | - `m`: The monad that `Select` ought to run in.
-- |
-- | See the below functions for documentation for the individual constructors.
-- | The README details how to use them in Halogen code, since the patterns
-- | are a little different.
data QueryF pq cs item m a
  = Search String a
  | Highlight Target a
  | Select Int a
  | CaptureRef Event a
  | Focus Boolean a
  | Key KE.KeyboardEvent a
  | PreventClick ME.MouseEvent a
  | SetVisibility Visibility a
  | GetVisibility (Visibility -> a)
  | ReplaceItems (Array item) a
  | Send (CQ.ChildQueryBox cs a)
  | Raise (pq Unit) a
  | Receive (Input pq cs item m) a

type Query pq cs item m = Free (QueryF pq cs item m)

-- | Trigger the relevant action with the event each time it occurs
always :: ∀ a b. a -> b -> Maybe a
always = const <<< Just

-- | Perform a new search with the included string.
search :: ∀ pq cs item m. String -> Query pq cs item m Unit
search s = liftF (Search s unit)

-- | Change the highlighted index to the next item, previous item, or a
-- | specific index.
highlight :: ∀ pq cs item m. Target -> Query pq cs item m Unit
highlight t = liftF (Highlight t unit)

-- | Triggers the "Selected" message for the item at the specified index.
select :: ∀ pq cs item m. Int -> Query pq cs item m Unit
select i = liftF (Select i unit)

-- | From an event, captures a reference to the element that triggered the
-- | event. Used to manage focus / blur for elements without requiring a
-- | particular identifier.
captureRef :: ∀ pq cs item m. Event -> Query pq cs item m Unit
captureRef r = liftF (CaptureRef r unit)

-- | Trigger the DOM focus event for the element we have a reference to.
triggerFocus :: ∀ pq cs item m. Query pq cs item m Unit
triggerFocus = liftF (Focus true unit)

-- | Trigger the DOM blur event for the element we have a reference to
triggerBlur :: ∀ pq cs item m. Query pq cs item m Unit
triggerBlur = liftF (Focus false unit)

-- | Register a key event. `TextInput`-driven components use these only for
-- | navigation, whereas `Toggle`-driven components also use the key stream for
-- | highlighting.
key :: ∀ pq cs item m. KE.KeyboardEvent -> Query pq cs item m Unit
key e = liftF (Key e unit)

-- | A helper query to prevent click events from bubbling up.
preventClick :: ∀ pq cs item m. ME.MouseEvent -> Query pq cs item m Unit
preventClick i = liftF (PreventClick i unit)

-- | Set the container visibility (`On` or `Off`)
setVisibility :: ∀ pq cs item m. Visibility -> Query pq cs item m Unit
setVisibility v = liftF (SetVisibility v unit)

-- | Get the container visibility (`On` or `Off`). Most useful when sequenced
-- | with other actions.
getVisibility :: ∀ pq cs item m. Query pq cs item m Visibility
getVisibility = liftF (GetVisibility identity)

-- | Toggles the container visibility.
toggleVisibility :: ∀ pq cs item m. Query pq cs item m Unit
toggleVisibility = getVisibility >>= not >>> setVisibility

-- | Replaces all items in state with the new array of items.
replaceItems :: ∀ pq cs item m. Array item -> Query pq cs item m Unit
replaceItems items = liftF (ReplaceItems items unit)

-- | A helper query that the component that mounts `Select` can use to embed its
-- | own queries. Triggers an `Emit` message containing the query when triggered.
-- | This can be used to easily extend `Select` with more behaviors.
raise :: ∀ pq cs item m. pq Unit -> Query pq cs item m Unit
raise pq = liftF (Raise pq unit)

-- | Sets the component with new input.
receive :: ∀ pq cs item m. Input pq cs item m -> Query pq cs item m Unit
receive i = liftF (Receive i unit)

-- | Represents a way to navigate on `Highlight` events: to the previous
-- | item, next item, or the item at a particular index.
data Target = Prev | Next | Index Int
derive instance eqTarget :: Eq Target

-- | Represents whether the component should display the item container. You
-- | should use this in your render function to control visibility:
-- |
-- | ```purescript
-- | render state = if state.visibility == On then renderAll else renderInputOnly
-- | ```
-- |
-- | This is a Boolean Algebra, where `On` corresponds to true, and `Off` to
-- | false, as one might expect. Thus, `not` will invert visibility.
data Visibility = Off | On
derive instance eqVisibility :: Eq Visibility
derive instance ordVisibility :: Ord Visibility

instance heytingAlgebraVisibility :: HeytingAlgebra Visibility where
  tt = On
  ff = Off
  not On = Off
  not Off = On
  conj On On = On
  conj _ _ = Off
  disj Off Off = Off
  disj _ _ = On
  implies On Off = Off
  implies _ _ = On
instance booleanAlgebraVisibility :: BooleanAlgebra Visibility

-- | Text-driven inputs will operate like a normal search-driven selection component.
-- | Toggle-driven inputs will capture key streams and debounce in reverse (only notify
-- | about searches when time has expired).
data InputType
  = TextInput
  | Toggle

-- | The component's state, once unpacked from `Store`.
-- |
-- | - `inputType`: Controls whether the component is input-driven or toggle-driven
-- | - `search`: The text the user has typed into the text input, or stream of keys
-- |             they have typed on the toggle.
-- | - `debounceTime`: How long, in milliseconds, before events should occur based
-- |                   on user searches.
-- | - `debouncer`: A representation of a running timer that, when it expires, will
-- |                trigger debounced events.
-- | - `inputElement`: A reference to the toggle or input element.
-- | - `items`: An array of user-provided `item`s.
-- | - `visibility`: Whether the array of items should be considered visible or not.
-- |                 Useful for rendering.
-- | - `highlightedIndex`: What item in the array of items should be considered
-- |                       highlighted. Useful for rendering.
-- | - `lastIndex`: The length of the array of items.
type State item =
  { inputType        :: InputType
  , search           :: String
  , debounceTime     :: Milliseconds
  , debouncer        :: Maybe Debouncer
  , inputElement     :: Maybe HTMLElement
  , items            :: Array item
  , visibility       :: Visibility
  , highlightedIndex :: Maybe Int
  , lastIndex        :: Int
  }

-- | Represents a running computation that, when it completes, will trigger debounced
-- | .cts.
type Debouncer =
  { var   :: AVar Unit
  , fiber :: Fiber Unit }

-- | The component's input type, which includes the component's render function. This
-- | render function can also be used to share data with the parent component, as every
-- | time the parent re-renders, the render function will refresh in `Select`.
type Input pq cs item m =
  { inputType     :: InputType
  , items         :: Array item
  , initialSearch :: Maybe String
  , debounceTime  :: Maybe Milliseconds
  , render        :: State item -> HTML pq cs item m
  }

-- | The parent is only notified for a few important events, but `Emit` makes it
-- | possible to raise arbitrary queries on events.
-- |
-- | - `Searched`: A new text search has been performed. Contains the text.
-- | - `Selected`: An item has been selected. Contains the item.
-- | - `VisibilityChanged`: The visibility has changed. Contains the new visibility.
-- | - `Emit`: An embedded query has been triggered and can now be evaluated.
-- |           Contains the query.
data Message pq item
  = Searched String
  | Selected item
  | VisibilityChanged Visibility
  | Emit (pq Unit)

component :: ∀ pq cs item m
  . MonadAff m
 => Component pq cs item m
component =
  H.component
    { initialState
    , render: extract
    , eval: eval'
    , receiver: Just <<< receive
    , initializer: Nothing
    , finalizer: Nothing
    }
  where
    initialState i = store i.render
      { inputType: i.inputType
      , search: fromMaybe "" i.initialSearch
      , debounceTime: fromMaybe (Milliseconds 0.0) i.debounceTime
      , debouncer: Nothing
      , inputElement: Nothing
      , items: i.items
      , highlightedIndex: Nothing
      , visibility: Off
      , lastIndex: length i.items - 1
      }

    -- Construct the fold over the free monad based on the stepwise eval
    eval' :: Query pq cs item m ~> DSL pq cs item m
    eval' a = foldFree eval a

    -- Helper for setting visibility inside `eval`. Eta-expanded bc strict
    -- mutual recursion woes.
    setVis v = eval' (setVisibility v)

    -- Just the normal Halogen eval
    eval :: QueryF pq cs item m ~> DSL pq cs item m
    eval = case _ of
      Search str a -> a <$ do
        st <- getState
        modifyState_ _ { search = str }
        setVis On

        case st.inputType, st.debouncer of
          TextInput, Nothing -> unit <$ do
            var   <- H.liftAff AVar.empty
            fiber <- H.liftAff $ forkAff do
              delay st.debounceTime
              AVar.put unit var

            -- This compututation will fork and run in the background. When the
            -- var is finally filled, the .ct will run (raise a new search)
            _ <- H.fork do
              _ <- H.liftAff $ AVar.take var
              modifyState_ _ { debouncer = Nothing, highlightedIndex = Just 0 }
              newState <- getState
              H.raise $ Searched newState.search

            modifyState_ _ { debouncer = Just { var, fiber } }

          TextInput, Just debouncer -> do
            let var = debouncer.var
            _ <- H.liftAff $ killFiber (error "Time's up!") debouncer.fiber
            fiber <- H.liftAff $ forkAff do
              delay st.debounceTime
              AVar.put unit var

            modifyState_ _ { debouncer = Just { var, fiber } }

          -- Key stream is not yet implemented. However, this should capture user
          -- key events and expire their search after a set number of milliseconds.
          _, _ -> pure unit

      Highlight target a -> a <$ do
        st <- getState
        when (st.visibility /= Off) $ do
          let highlightedIndex = case target of
                Prev  -> case st.highlightedIndex of
                  Just i | i /= 0 ->
                    Just (i - 1)
                  _ ->
                    Just st.lastIndex
                Next  -> case st.highlightedIndex of
                  Just i | i /= st.lastIndex ->
                    Just (i + 1)
                  _ ->
                    Just 0
                Index i ->
                  Just i
          modifyState_ _ { highlightedIndex = highlightedIndex }
        pure unit

      Select index a -> a <$ do
        st <- getState
        when (st.visibility == On) $
          for_ (st.items !! index)
            \item -> H.raise (Selected item)

      CaptureRef event a -> a <$ do
        st <- getState
        modifyState_ _ { inputElement = fromEventTarget =<< currentTarget event }
        pure a

      Focus focusOrBlur a -> a <$ do
        st <- getState
        traverse_ (H.liftEffect <<< if focusOrBlur then focus else blur) st.inputElement

      Key ev a -> a <$ do
        setVis On
        let preventIt = H.liftEffect $ preventDefault $ KE.toEvent ev
        case KE.code ev of
          "ArrowUp"   -> preventIt *> eval' (highlight Prev)
          "ArrowDown" -> preventIt *> eval' (highlight Next)
          "Escape"    -> do
            st <- getState
            preventIt
            for_ st.inputElement (H.liftEffect <<< blur)
          "Enter"     -> do
            st <- getState
            preventIt
            for_ st.highlightedIndex (eval' <<< select)
          otherKey    -> pure unit

      PreventClick ev a -> a <$ do
        H.liftEffect <<< preventDefault <<< ME.toEvent $ ev

      SetVisibility v a -> a <$ do
        st <- getState
        when (st.visibility /= v) do
          modifyState_ _ { visibility = v, highlightedIndex = Just 0 }
          H.raise $ VisibilityChanged v

      GetVisibility f -> do
        st <- getState
        pure (f st.visibility)

      ReplaceItems items a -> a <$ do
        modifyState_ _
          { items = items
          , lastIndex = length items - 1
          , highlightedIndex = Nothing }

      Send box -> do
        H.HalogenM $ liftF $ H.ChildQuery box

      Raise parentQuery a -> a <$ do
        H.raise (Emit parentQuery)

      Receive input a -> a <$ do
        modifyStore input.render identity
