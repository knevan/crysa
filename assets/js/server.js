import components from "../vue"
import manifest from "live_vue/ssrManifest"
import { getRender } from "live_vue/server"

// present only in prod build. Returns empty obj if doesn't exist
// used to render preload links
const manifest = loadManifest("../priv/static/.vite/ssr-manifest.json")
export const render = getRender(components, manifest)