export const createMenuRuntimeCommandRunner = ({ activeMonacoEditor, runMonacoEditorAction, runDocumentCommand, applyAppZoom }) => {
  return (action) => {
    const editor = activeMonacoEditor();

    switch (action) {
      case "undo":
        return editor ? runMonacoEditorAction(editor, "undo") : runDocumentCommand("undo");
      case "redo":
        return editor ? runMonacoEditorAction(editor, "redo") : runDocumentCommand("redo");
      case "cut":
        return editor
          ? runMonacoEditorAction(editor, "editor.action.clipboardCutAction")
          : runDocumentCommand("cut");
      case "copy":
        return editor
          ? runMonacoEditorAction(editor, "editor.action.clipboardCopyAction")
          : runDocumentCommand("copy");
      case "paste":
        return editor
          ? runMonacoEditorAction(editor, "editor.action.clipboardPasteAction")
          : runDocumentCommand("paste");
      case "delete":
        return editor ? runMonacoEditorAction(editor, "deleteLeft") : runDocumentCommand("delete");
      case "select_all":
        return editor
          ? runMonacoEditorAction(editor, "editor.action.selectAll")
          : runDocumentCommand("selectAll");
      case "find":
        return editor ? runMonacoEditorAction(editor, "actions.find") : false;
      case "replace":
        return editor ? runMonacoEditorAction(editor, "editor.action.startFindReplaceAction") : false;
      case "reload":
      case "force_reload":
        window.location.reload();
        return true;
      case "reset_zoom":
        applyAppZoom(1);
        return true;
      case "zoom_in":
        applyAppZoom((window.__bdsAppZoom || 1) + 0.1);
        return true;
      case "zoom_out":
        applyAppZoom((window.__bdsAppZoom || 1) - 0.1);
        return true;
      case "toggle_full_screen":
        if (document.fullscreenElement) {
          document.exitFullscreen?.();
        } else {
          document.documentElement.requestFullscreen?.();
        }

        return true;
      default:
        return false;
    }
  };
};
