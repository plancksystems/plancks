<script setup>
import { ref, onMounted } from 'vue'
import pqlContent from './pql-guide.md?raw'

const sections = ref([])

onMounted(() => {
  sections.value = parseMarkdown(pqlContent)
})

function parseMarkdown(md) {
  const lines = md.split('\n')
  const result = []
  let current = null
  let buffer = []

  function flushBuffer() {
    if (buffer.length > 0 && current) {
      current.blocks.push(...parseBlocks(buffer))
      buffer = []
    }
  }

  for (const line of lines) {
    if (line.startsWith('# ') && !line.startsWith('## ')) {
      flushBuffer()
      current = { title: line.slice(2).trim(), level: 1, blocks: [] }
      result.push(current)
    } else if (line.startsWith('## ')) {
      flushBuffer()
      current = { title: line.slice(3).trim(), level: 2, blocks: [] }
      result.push(current)
    } else if (line === '---') {
      flushBuffer()
    } else {
      buffer.push(line)
    }
  }
  flushBuffer()
  return result
}

function parseBlocks(lines) {
  const blocks = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i]

    if (line.startsWith('```')) {
      const lang = line.slice(3).trim()
      const codeLines = []
      i++
      while (i < lines.length && !lines[i].startsWith('```')) {
        codeLines.push(lines[i])
        i++
      }
      i++
      blocks.push({ type: 'code', lang, content: codeLines.join('\n') })
      continue
    }

    if (line.includes('|') && line.trim().startsWith('|')) {
      const tableLines = []
      while (i < lines.length && lines[i].includes('|') && lines[i].trim().startsWith('|')) {
        tableLines.push(lines[i])
        i++
      }
      blocks.push(parseTable(tableLines))
      continue
    }

    if (line.trim() === '') {
      i++
      continue
    }

    blocks.push({ type: 'text', content: line })
    i++
  }

  return blocks
}

function parseTable(lines) {
  if (lines.length < 2) return { type: 'text', content: lines.join('\n') }

  const parseRow = (line) =>
    line.split('|').slice(1, -1).map(c => c.trim())

  const headers = parseRow(lines[0])
  const rows = lines.slice(2).map(parseRow)

  return { type: 'table', headers, rows }
}
</script>

<template>
  <div class="flex-1 flex flex-col min-w-0 overflow-hidden bg-white">
    <div class="bg-slate-100 border-b border-slate-200 px-4 py-2 flex items-center">
      <span class="text-sm font-medium text-slate-700">PQL Reference</span>
    </div>

    <div class="flex-1 overflow-y-auto light-scroll">
      <div class="max-w-3xl mx-auto px-6 py-6">
        <template v-for="(section, si) in sections" :key="si">
          <h1 v-if="section.level === 1" class="text-xl font-bold text-slate-800 mb-3">{{ section.title }}</h1>
          <h2 v-else class="text-base font-semibold text-slate-700 mt-6 mb-2 pb-1 border-b border-slate-200">
            {{ section.title }}</h2>

          <template v-for="(block, bi) in section.blocks" :key="bi">
            <pre v-if="block.type === 'code'"
              class="bg-slate-900 text-green-400 text-xs leading-relaxed rounded px-4 py-3 my-2 overflow-x-auto font-mono">{{ block.content }}
            </pre>

            <div v-else-if="block.type === 'table'" class="my-2 overflow-x-auto">
              <table class="w-full text-xs border-collapse">
                <thead>
                  <tr>
                    <th v-for="(h, hi) in block.headers" :key="hi"
                      class="text-left px-3 py-1.5 bg-slate-100 border border-slate-200 font-semibold text-slate-600">
                      {{ h }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="(row, ri) in block.rows" :key="ri">
                    <td v-for="(cell, ci) in row" :key="ci" class="px-3 py-1.5 border border-slate-200 text-slate-700">
                      <code v-if="cell.startsWith('`') && cell.endsWith('`')"
                        class="bg-slate-100 px-1 rounded text-slate-800 font-mono">{{ cell.slice(1, -1) }}</code>
                      <template v-else>{{ cell }}</template>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p v-else class="text-xs text-slate-600 my-1 leading-relaxed">
              <template v-for="(part, pi) in inlineParse(block.content)" :key="pi">
                <strong v-if="part.bold" class="font-semibold text-slate-700">{{ part.text }}</strong>
                <code v-else-if="part.code"
                  class="bg-slate-100 px-1 rounded text-slate-800 font-mono text-[11px]">{{ part.text }}</code>
                <template v-else>{{ part.text }}</template>
              </template>
            </p>
          </template>
        </template>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  methods: {
    inlineParse(text) {
      const parts = []
      const regex = /(\*\*(.+?)\*\*|`(.+?)`)/g
      let last = 0
      let match

      while ((match = regex.exec(text)) !== null) {
        if (match.index > last) {
          parts.push({ text: text.slice(last, match.index) })
        }
        if (match[2]) {
          parts.push({ text: match[2], bold: true })
        } else if (match[3]) {
          parts.push({ text: match[3], code: true })
        }
        last = match.index + match[0].length
      }

      if (last < text.length) {
        parts.push({ text: text.slice(last) })
      }

      return parts.length ? parts : [{ text }]
    }
  }
}
</script>
