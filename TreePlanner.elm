module TreePlanner where

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Lazy exposing (lazy, lazy2, lazy3)

import Json.Decode as Decoder
import Json.Decode exposing ((:=))
import Json.Encode as Encoder
import Set
import String
import Utils

import Signal
import Signal exposing (Signal, (<~))
import Window
import Keyboard

import Tree as T
import Tree exposing (Tree, NodeMovement)

import Markdown

import Debug

---------- MODEL ----------

-- Application state
type alias State = {
    ui : UIState,
    rootNode : Tree Item,
    projectTitle : String,
    selectedId : Int
}

type alias UIState = {
    confirmationDialog : Maybe Dialog,
    context : Context,
    lastContext : Context,
    lastSelectedId : Int
}

type alias Item = {
    title : String,
    content : String,
    expanded : Bool
}

type alias Dialog = {
    query          : String,
    confirm        : Action,
    cancel         : Action,
    selectedOption : Int
}

type alias Event = {
    action : Action,
    setContext : Maybe Context
}

newItem : Item 
newItem = {
    title = "new",
    content = "",
    expanded = True
    }

emptyModel : State
emptyModel = {
    rootNode = T.newNode T.Empty newItem [], 
    projectTitle = "",
    selectedId = 0,
    ui = emptyUIState
    }

emptyDialog : Dialog
emptyDialog = {
    query = "",
    confirm = NoOp,
    cancel = Cancel, 
    selectedOption = 0
    }

emptyEvent : Event
emptyEvent = {
    action = NoOp,
    setContext = Nothing
    }

emptyUIState : UIState
emptyUIState = {
    confirmationDialog = Nothing,
    context = Default,
    lastContext = Default,
    lastSelectedId = -1
    }

newProjectEvent = { emptyEvent | action <- Confirm 
                    { emptyDialog | query <- "Are you sure you want to create a new project? Any unsaved progress will be lost.",
                                    confirm <- NewProject
                    }
                }

deleteNodeEvent = { emptyEvent | action <- Confirm 
                        { emptyDialog |
                            query   <- "Are you sure you want to delete this item and all sub-items?",
                            confirm <- DeleteItem
                        }
                    }

---------- UPDATE ----------

type Action 
    = NewItem
    | SetAllExpanded Bool
    | Confirm Dialog
    | Cancel
    | ChangeConfirmSelection Int
    | NewProject
    | UpdateItemTitle String
    | LoadProject State
    | SelectItem Int
    | MoveSelection SelectionMovement
    | RenameItem String
    | UpdateItem String
    | RenamingItem (Maybe Int)
    | RenameProject String
    | DeleteItem
    | MoveNode NodeMovement
    | ToggleExpanded (Maybe Int)
    | NoOp

type SelectionMovement = Up | Down

type Context = Default | TextInput | ConfirmDialog | TitleInput | MainTextArea | RenamingNode

type Input = KeyboardEvent (List Int) | UIEvent Event

update : Input -> State -> State
update input s = let
        event = case input of
            KeyboardEvent keys -> keyPressesToEvent keys s
            UIEvent e          -> e

        ui' = s.ui
        oldContext = s.ui.context
        newContext = Maybe.withDefault s.ui.context event.setContext
        state = { s | ui <- { ui' | context <- newContext, 
                                    lastContext <- if newContext /= oldContext 
                                                   then oldContext 
                                                   else s.ui.lastContext,
                                    lastSelectedId <- s.selectedId
                            } 
                } 
        ui = state.ui

        confirmationDialog = state.ui.confirmationDialog

        selectableNodes = T.mapN (\(T.Node value children id) -> if not value.expanded then (T.Node value [] id) else (T.Node value children id)) state.rootNode
    in case event.action of
        NewItem -> let
            parent = T.nodeByIdWithDefault (T.dummyNode newItem) state.selectedId state.rootNode
            child = T.newNode state.rootNode newItem []
            newTree = T.addChildTo parent child state.rootNode
                      |> T.moveNode T.Lift child
                      |> T.valueM (\item -> { item | expanded <- True })
            in { state | rootNode <- newTree, selectedId <- T.id child }

        NewProject -> emptyModel

        SetAllExpanded expanded -> { state | rootNode <- T.map (\item -> { item | expanded <- expanded }) state.rootNode, selectedId <- if expanded then state.selectedId else 0 }

        LoadProject model -> model

        UpdateItemTitle newTitle -> { state | rootNode <- T.mapToNodeById (\item -> { item | title <- newTitle }) state.selectedId state.rootNode }

        Confirm dialog -> { state | ui <- { ui | confirmationDialog <- Just dialog, context <- ConfirmDialog } }

        Cancel -> { state | ui <- { ui | confirmationDialog <- Nothing, context <- Default } }

        ChangeConfirmSelection selection -> { state | ui <- { ui | confirmationDialog <- Maybe.map (\cd -> { cd | selectedOption <- selection } ) confirmationDialog } }

        SelectItem selectedId -> { state | selectedId <- selectedId }

        RenameProject newName -> { state | projectTitle <- newName }

        MoveSelection dir -> case dir of
            Up -> { state | selectedId <- T.id <| Maybe.withDefault (T.Node newItem [] 0) <| List.head <| List.reverse <| Utils.takeWhile ((/=) state.selectedId << T.id) (T.flatten selectableNodes) }
            Down -> { state | selectedId <- T.id <| Maybe.withDefault (T.Node newItem [] state.selectedId) <| List.head <| List.drop 1 <| Utils.dropWhile ((/=) state.selectedId << T.id) (T.flatten selectableNodes) }

        RenameItem newName -> 
            { state | rootNode <- T.mapToNodeById (\item -> { item | title <- newName }) state.selectedId state.rootNode, 
                      ui       <- { ui | context <- Default }
            }

        UpdateItem newContent ->
            { state | rootNode <- T.mapToNodeById (\item -> { item | content <- newContent }) state.selectedId state.rootNode }

        RenamingItem selectedId -> case selectedId of
            Just sId -> { state | selectedId <- sId, ui <- { ui | context <- RenamingNode } }
            Nothing  -> { state | ui <- { ui | context <- RenamingNode } }

        DeleteItem -> let
                previousNode = Maybe.withDefault (T.dummyNode newItem) <| List.head <| List.reverse 
                               <| Utils.takeWhile ((/=) (T.nodeByIdWithDefault (T.dummyNode newItem) state.selectedId state.rootNode)) (T.flatten selectableNodes)
                prevId = if T.id previousNode < 0 then 0 else T.id previousNode
            in { state | rootNode <- T.removeNodeById state.selectedId state.rootNode, 
                         selectedId <- prevId, 
                         ui <- { ui | confirmationDialog <- Nothing }
               }

        MoveNode movement -> case movement of
            T.Lower -> let 
                newState = { state | rootNode <- T.moveNodeById movement state.selectedId state.rootNode }
                parent = T.parent (T.nodeByIdWithDefault state.rootNode state.selectedId newState.rootNode) newState.rootNode |> Maybe.withDefault state.rootNode
                in { newState | rootNode <- T.mapToNodeById (\item -> { item | expanded <- True }) (T.id parent) newState.rootNode }

            _       -> { state | rootNode <- T.moveNodeById movement state.selectedId state.rootNode }

        ToggleExpanded selectedId -> case selectedId of
            Just sId -> let
                toggledNode = T.nodeByIdWithDefault (T.dummyNode newItem) sId state.rootNode
                in case T.nodeById state.selectedId toggledNode of
                    Just _ -> 
                        { state | 
                            rootNode <- T.mapToNodeById (\item -> { item | expanded <- not item.expanded }) sId state.rootNode,
                            selectedId <- sId 
                        }
                    Nothing -> { state | rootNode <- T.mapToNodeById (\item -> { item | expanded <- not item.expanded }) sId state.rootNode }
            Nothing  -> 
                { state | rootNode <- T.mapToNodeById (\item -> { item | expanded <- not item.expanded }) state.selectedId state.rootNode }

        _ -> state

keyPressesToEvent : List Int -> State -> Event
keyPressesToEvent keypresses state = case keypresses of
    [17, 191] -> newProjectEvent
    _ -> case state.ui.context of
        Default -> case keypresses of 
            [17, 37] -> { emptyEvent | action <- MoveNode T.Lift }
            [17, 38] -> { emptyEvent | action <- MoveNode T.ShiftUp }
            [17, 39] -> { emptyEvent | action <- MoveNode T.Lower }
            [17, 40] -> { emptyEvent | action <- MoveNode T.ShiftDown }
            [13, 17] -> { emptyEvent | action <- NewItem }
            [46]     -> deleteNodeEvent
            [32]     -> { emptyEvent | action <- ToggleExpanded Nothing }
            [13]     -> { emptyEvent | action <- RenamingItem Nothing }
            [38]     -> { emptyEvent | action <- MoveSelection Up }
            [40]     -> { emptyEvent | action <- MoveSelection Down }
            [27]     -> { emptyEvent | setContext <- Just TitleInput }
            [9]      -> { emptyEvent | setContext <- Just MainTextArea }
            _        -> emptyEvent

        ConfirmDialog -> let
            dialog = Maybe.withDefault emptyDialog state.ui.confirmationDialog
            confirmAction = (if dialog.selectedOption == 0 then .confirm else .cancel) dialog
            in case keypresses of
                [13]     -> { emptyEvent | action <- confirmAction, setContext <- Just Default }
                [27]     -> { emptyEvent | action <- dialog.cancel, setContext <- Just Default }
                [37]     -> { emptyEvent | action <- ChangeConfirmSelection 0 }
                [39]     -> { emptyEvent | action <- ChangeConfirmSelection 1 }
                _        -> emptyEvent

        TitleInput -> case keypresses of
            [9]      -> { emptyEvent | setContext <- Just state.ui.lastContext }
            [13]     -> { emptyEvent | setContext <- Just state.ui.lastContext }
            [27]     -> { emptyEvent | setContext <- Just state.ui.lastContext }
            _        -> emptyEvent

        MainTextArea -> case keypresses of
            [9]          -> { emptyEvent | setContext <- Just Default }
            [27]         -> { emptyEvent | setContext <- Just TitleInput }
            _        -> emptyEvent

        RenamingNode -> case keypresses of
            [9]          -> { emptyEvent | setContext <- Just MainTextArea }
            [13]         -> { emptyEvent | setContext <- Just Default }
            [38]         -> { emptyEvent | setContext <- Just Default }
            [40]         -> { emptyEvent | setContext <- Just Default }
            _            -> emptyEvent

        _ -> emptyEvent

---------- VIEW ----------

view : State -> (Int, Int) -> Html
view state (w, h) = let
        dialog = Maybe.withDefault emptyDialog state.ui.confirmationDialog
        showConfirmDialog = state.ui.context == ConfirmDialog
    in div [class "wrapper"] [
        div [
            classList [("modal-background", True), ("no-display", not showConfirmDialog)],
            onClick uiEvent.address { emptyEvent | action <- dialog.cancel, setContext <- Just Default }
        ] [],
        div [
            classList [("confirm-dialog", True), ("no-display", not showConfirmDialog)],
            style [("top", toString (h//2 - 167) ++ "px"),("left", toString (w//2 - 257) ++ "px")]
        ] [
            h2 [] [text dialog.query],
            div [] [
                button [
                    classList [("confirm-button", dialog.selectedOption == 0), ("cancel-button", dialog.selectedOption /= 0)],
                    onClick uiEvent.address { emptyEvent | action <- dialog.confirm, setContext <- Just Default }
                ] [text "Confirm"],
                button [
                    classList [("confirm-button", dialog.selectedOption /= 0), ("cancel-button", dialog.selectedOption == 0)],
                    onClick uiEvent.address { emptyEvent | action <- dialog.cancel, setContext <- Just Default }
                ] [text "Cancel"]
            ]
        ],
        div [class "title-bar"] [
            input [
                id "title-bar-input",
                if state.ui.context == TitleInput then style [] else value state.projectTitle,
                type' "text", 
                on "input" targetValue (Signal.message uiEvent.address << (\act ->
                    { emptyEvent | action <- act }
                ) << RenameProject),
                onFocus uiEvent.address { emptyEvent | setContext <- Just TitleInput },
                placeholder "Untitled Project"
            ] []
        ],
        div [class "options-bar", onClick uiEvent.address {emptyEvent | setContext <- Just Default } ] [
            i [class "fa fa-file-text-o icon", onClick uiEvent.address newProjectEvent, alt "New Project (Ctrl+/)", title "New Project (Ctrl+/)"] [],
            i [class "fa fa-download icon", onClick saveFile.address (), alt "Save Project  (Ctrl+S)", title "Save Project (Ctrl+S)"] [],
            label [for "loadButton"] [
                Html.form [id "loadWrapperForm"] [ 
                    input  [type' "file", id "loadButton"] [text "Load"],
                    i [class "fa fa-upload icon", alt "Load Project (Ctrl+O)", title "Load Project (Ctrl+O)"] []
                ]
            ],
            div [class "divider"] [],
            i [class "fa fa-plus-square-o icon", onClick uiEvent.address { emptyEvent | action <- NewItem, setContext <- Just Default }, alt "New Node (Ctrl+Return)", title "New Node (Ctrl+Return)" ] [], 
            i [class "fa fa-pencil icon", onClick uiEvent.address { emptyEvent | action <- RenamingItem Nothing }, alt "Rename Node (Return)", title "Rename Node (Return)"] [],
            i [class "fa fa-arrows-v icon", onClick uiEvent.address { emptyEvent | action <- ToggleExpanded Nothing }, alt "Toggle Expanded (Space)", title "Toggle Expanded (Space)"] [],
            i [class "fa fa-trash-o icon", onClick uiEvent.address deleteNodeEvent, alt "Delete Node (Del)", title "Delete Node (Del)" ] [], 
            div [class "divider"] [],
            i [class "fa fa-arrow-left icon", onClick uiEvent.address { emptyEvent | action <- MoveNode T.Lift, setContext <- Just Default }, alt "Move Left (Ctrl+Left)", title "Move Left (Ctrl+Left)" ] [], 
            i [class "fa fa-arrow-up icon", onClick uiEvent.address { emptyEvent | action <- MoveNode T.ShiftUp, setContext <- Just Default }, alt "Move Up (Ctrl+Up)", title "Move Up (Ctrl+Up)" ] [], 
            i [class "fa fa-arrow-down icon", onClick uiEvent.address { emptyEvent | action <- MoveNode T.ShiftDown, setContext <- Just Default }, alt "Move Down (Ctrl+Down)", title "Move Down (Ctrl+Down)" ] [], 
            i [class "fa fa-arrow-right icon", onClick uiEvent.address { emptyEvent | action <- MoveNode T.Lower, setContext <- Just Default }, alt "Move Right (Ctrl+Right)", title "Move Right (Ctrl+Right)" ] [],
            div [class "divider"] [],
            i [class "fa fa-caret-square-o-up icon", onClick uiEvent.address { emptyEvent | action <- SetAllExpanded False, setContext <- Just Default }, alt "Collapse All", title "Collapse All" ] [],
            i [class "fa fa-caret-square-o-down icon", onClick uiEvent.address { emptyEvent | action <- SetAllExpanded True, setContext <- Just Default }, alt "Expand All", title "Expand All" ] []
        ],
        div [
            class "main-container",
            style [("height", toString (h-140) ++ "px")]
        ] [
            div [
                class "tree-pane",
                onClick uiEvent.address { emptyEvent | setContext <- Just Default }
            ] [lazy2 treeToHtmlTree state state.rootNode],
            label [for "textbox"] [
                div [
                    class "text-area-container"
                ] [
                    textarea [
                        id "textbox",
                        placeholder "...",
                        on "input" targetValue (Signal.message uiEvent.address << (\act -> 
                            { emptyEvent | action <- act }
                        ) << UpdateItem),
                        onFocus uiEvent.address { emptyEvent | setContext <- Just MainTextArea }
                    ] []
                ]
            ]
        ],
        footer [] [
            Markdown.toHtml """ Created by <a href="http://robertjwhitaker.com" target="_blank">Robert J. Whitaker</a>

*This project was programmed in <a href="http://elm-lang.org" target="_blank">Elm</a>. Check out the <a href="https://github.com/robwhitaker/Elm-Tree-Planner" target="_blank">source</a>.*
"""
        ]
    ]

treeToHtmlTree : State -> Tree Item -> Html
treeToHtmlTree state (T.Node item children id') = let
        liContent = if state.ui.context == RenamingNode && id' == state.selectedId
                    then 
                        input [ 
                            type' "text",
                            id ("node-" ++ toString id'), 
                            onClick uiEvent.address { emptyEvent | action <- SelectItem id', setContext <- Just RenamingNode }, 
                            on "input" targetValue (Signal.message uiEvent.address << (\act -> { emptyEvent | action <- act }) << UpdateItemTitle)
                        ] []
                    else 
                        div [
                            id ("node-" ++ toString id'),
                            classList [
                                ("item-title", True),
                                ("selected-focused", id' == state.selectedId && state.ui.context == Default), 
                                ("selected-unfocused", id' == state.selectedId && (not <| state.ui.context == Default))
                            ],
                            onClick uiEvent.address { emptyEvent | action <- SelectItem id', setContext <- Just Default }, 
                            onDoubleClick uiEvent.address { emptyEvent | action <- RenamingItem (Just id') }
                        ] [text item.title]
        in ul [classList [("root-node", id' == 0)]] [
            li [
                classList [("hidden", not item.expanded && children /= [])]
            ] <| 
                div [class "arrow-container"] [
                    img [
                        class "expand-arrow-icon",
                        src (if item.expanded then "arrow-expanded.png" else "arrow-collapsed.png"), 
                        onClick uiEvent.address { emptyEvent | action <- ToggleExpanded (Just id') }
                    ] []
                ] 
                :: liContent 
                :: (if item.expanded then List.map (lazy2 treeToHtmlTree state) children else [])]

---------- INPUTS ----------

main : Signal Html
main = Signal.map2 view state Window.dimensions

initialModel : State
initialModel = decodeState getStorage |> \result -> case result of
    Ok model -> let
        ui = model.ui
        in { model | ui <- { ui | context <- Default } }
    _        -> emptyModel

state : Signal State
state = Signal.foldp update initialModel inputEvent

keyboardInput : Signal (List Int)
keyboardInput = Set.toList <~ Signal.dropRepeats Keyboard.keysDown 

load : Signal Event
load = (decodeState >> \result -> case result of
    Ok model -> { emptyEvent | action <- Confirm
                    { emptyDialog | 
                        query   <- "Are you sure you want to open this file? Any unsaved progress will be lost.",
                        confirm <- let
                            ui = model.ui
                            in LoadProject { model | ui <- { ui | context <- Default } } 
                    }
                }
    Err _    -> emptyEvent
    ) <~ fileUpload

inputEvent : Signal Input
inputEvent = Signal.mergeMany [UIEvent <~ uiEvent.signal, KeyboardEvent <~ keyboardInput, UIEvent <~ load]

sendSave : Signal ()
sendSave = Signal.merge saveFile.signal <| Signal.filterMap (\keys -> if keys == [17, 83] then Just () else Nothing) () keyboardInput

---------- MAILBOXES ----------

uiEvent : Signal.Mailbox Event
uiEvent = Signal.mailbox emptyEvent

saveFile : Signal.Mailbox ()
saveFile = Signal.mailbox ()

errBox : Signal.Mailbox ()
errBox = Signal.mailbox ()

---------- PORTS ----------

port focus : Signal (String, Maybe String)
port focus = Signal.filter ((/=) "" << fst) ("", Nothing) 
          <| Signal.dropRepeats 
          <| Signal.map (\s -> case s.ui.context of
                                RenamingNode -> ("#node-" ++ toString s.selectedId, Maybe.map (.title << T.value) <| T.nodeById s.selectedId s.rootNode)
                                TitleInput   -> ("#title-bar-input", Just s.projectTitle)
                                MainTextArea -> ("#textbox", Nothing)
                                _ -> ("default", Nothing)
                        ) state

port scroll : Signal String
port scroll = Signal.map (\s -> "#node-" ++ toString s.selectedId) state

port textBoxText : Signal String
port textBoxText = let
    isSelection = Signal.map (\s -> s.selectedId /= s.ui.lastSelectedId) state 
    in Signal.sampleOn (Signal.merge (Signal.filter identity False isSelection) ticker)
    <| Signal.map (\s -> Maybe.withDefault "" <| Maybe.map (.content << T.value) <| T.nodeById s.selectedId s.rootNode) state

port save : Signal (String, String)
port save = let
    fileName = String.words >> String.join "_"
    in
        Signal.sampleOn sendSave
        <| Signal.map (\s -> (,)
                             (if s.projectTitle == "" then "untitled" else fileName s.projectTitle) 
                             (encodeState s)
                      ) state
        
port getStorage : String

port ticker : Signal Bool

port setStorage : Signal String
port setStorage = Signal.map encodeState state 

port fileUpload : Signal String

port log : Signal String
port log = Signal.constant ""

---------- HELPERS ----------

encodeState : State -> String
encodeState s = let
    encodeItem item = Encoder.object [
            ("title", Encoder.string item.title),
            ("content", Encoder.string item.content),
            ("expanded", Encoder.bool item.expanded)
        ]
    
    encodeTree (T.Node value children id) = 
        Encoder.object [
            ("value", encodeItem value),
            ("children", List.map encodeTree children |> Encoder.list),
            ("id", Encoder.int id)
        ]

    encodeState' s = 
        Encoder.object [
            ("rootNode", encodeTree s.rootNode),
            ("projectTitle", Encoder.string s.projectTitle),
            ("selectedId", Encoder.int s.selectedId)
        ]
    in Encoder.encode 0 <| encodeState' s

decodeState : String -> Result String State
decodeState s = let 
    itemDecoder  = Decoder.object3 Item ("title"    := Decoder.string) 
                                        ("content"  := Decoder.string) 
                                        ("expanded" := Decoder.bool)

    lazy : (() -> Decoder.Decoder a) -> Decoder.Decoder a
    lazy thunk =
      Decoder.customDecoder Decoder.value
          (\js -> Decoder.decodeValue (thunk ()) js)

    treeDecoder  = Decoder.object3 T.Node ("value"    := itemDecoder) 
                                          ("children" := Decoder.list (lazy (\_ -> treeDecoder))) 
                                          ("id"       := Decoder.int)

    stateDecoder = Decoder.object3 (State emptyUIState) 
                                         ("rootNode"            := treeDecoder)
                                         ("projectTitle"        := Decoder.string) 
                                         ("selectedId"          := Decoder.int)
    in (Decoder.decodeString stateDecoder s) 
