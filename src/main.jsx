import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { queryClient } from './lib/queryClient'
import App from './App'
// Crate fork: Maven Pro is bundled (was fetched from fonts.googleapis.com).
import '@fontsource/maven-pro/latin-400.css'
import '@fontsource/maven-pro/latin-500.css'
import '@fontsource/maven-pro/latin-600.css'
import '@fontsource/maven-pro/latin-700.css'
import '@fontsource/maven-pro/latin-800.css'
import '@fontsource/maven-pro/latin-900.css'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  </React.StrictMode>,
)
