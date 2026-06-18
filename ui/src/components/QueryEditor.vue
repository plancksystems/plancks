<script setup>
import { ref } from 'vue'

const model = defineModel()
const emit = defineEmits(['execute'])
const textarea = ref(null)

function onKeydown(e) {
  if ((e.ctrlKey || e.metaKey) && (e.key === 'Enter' || e.key === 'r')) {
    e.preventDefault()
    emit('execute')
  }
}

function getTextarea() {
  return textarea.value
}

defineExpose({ getTextarea })
</script>

<template>
  <div class="h-[30%] bg-white border-b border-slate-200 flex flex-col overflow-hidden">
    <textarea
      ref="textarea"
      :value="model"
      @input="model = $event.target.value"
      @keydown="onKeydown"
      class="flex-1 p-4 font-mono text-sm bg-white text-slate-700 border-0 focus:outline-none resize-none"
      placeholder="// Write your PQL query here&#10;// Separate multiple queries with ;&#10;// e.g., sales.products.filter(price > 100).limit(10)&#10;// Press Ctrl+R / Cmd+R to execute"
      spellcheck="false"
    />
  </div>
</template>
