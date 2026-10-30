/* cspell:ignore apikey */
/**
 * Redacts credential-shaped values out of the captured contract fixtures.
 *
 * Deny by default: the string value of ANY key whose name reads like a credential is
 * replaced, at any depth. The explicit `vimeo.{clientSecret,accessToken,clientID}` pass stays
 * as well, because `clientID` does not match the name pattern and is still a credential.
 *
 * Usage: node redact.mjs <directory>   — rewrites the six fixture files in place.
 */
import fs from 'node:fs'
import path from 'node:path'

const FILES = ['manifest.json', 'home.json', 'browse.json', 'live.json', 'show.json', 'episode.json']
const CREDENTIAL_KEY = /secret|token|password|credential|apikey/i
const VIMEO_KEYS = ['clientSecret', 'accessToken', 'clientID']
const PLACEHOLDER = 'REDACTED'

/** Every credential-shaped string value in the tree, by value. */
function collect(node, found) {
  if (!node || typeof node !== 'object') {
    return
  }

  if (Array.isArray(node)) {
    for (const item of node) {
      collect(item, found)
    }

    return
  }

  for (const [key, value] of Object.entries(node)) {
    if (typeof value === 'string' && value && value !== PLACEHOLDER && CREDENTIAL_KEY.test(key)) {
      found.add(value)
    }

    if (key === 'vimeo' && value && typeof value === 'object') {
      for (const vimeoKey of VIMEO_KEYS) {
        const candidate = value[vimeoKey]

        if (typeof candidate === 'string' && candidate && candidate !== PLACEHOLDER) {
          found.add(candidate)
        }
      }
    }

    collect(value, found)
  }
}

const dir = process.argv[2]

if (!dir) {
  console.error('usage: node redact.mjs <directory>')
  process.exit(1)
}

const found = new Set()

for (const file of FILES) {
  collect(JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8')), found)
}

// Replace by value, across every file: one credential may appear in several bodies.
let replacements = 0

for (const file of FILES) {
  const target = path.join(dir, file)
  let body = fs.readFileSync(target, 'utf8')

  for (const secret of found) {
    const parts = body.split(secret)

    replacements += parts.length - 1
    body = parts.join(PLACEHOLDER)
  }

  fs.writeFileSync(target, body)
}

console.log(`redacted ${found.size} credential values, ${replacements} occurrences`)
