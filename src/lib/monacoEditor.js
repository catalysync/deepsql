// Crate fork: serve Monaco from our own bundle instead of cdn.jsdelivr.net.
//
// @monaco-editor/react's loader fetches Monaco from jsDelivr at runtime unless
// it is handed a local instance via loader.config({ monaco }). Every editor in
// the app imports this module instead of '@monaco-editor/react' directly.
// See docs/crate/TELEMETRY-REMOVED.md.
import * as monaco from 'monaco-editor'
import EditorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker'
import JsonWorker from 'monaco-editor/esm/vs/language/json/json.worker?worker'
import HtmlWorker from 'monaco-editor/esm/vs/language/html/html.worker?worker'
import Editor, { loader } from '@monaco-editor/react'

self.MonacoEnvironment = {
  getWorker(_workerId, label) {
    if (label === 'json') return new JsonWorker()
    if (label === 'html' || label === 'handlebars' || label === 'razor') return new HtmlWorker()
    return new EditorWorker()
  },
}

loader.config({ monaco })

export default Editor
