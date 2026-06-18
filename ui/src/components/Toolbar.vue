<script setup>
defineProps({
  status: Object,
})

const emit = defineEmits(['execute', 'format'])

const dotClass = {
  running: 'bg-yellow-500 animate-pulse',
  error: 'bg-red-500',
  ready: 'bg-green-500',
}
const textClass = {
  running: 'text-yellow-700',
  error: 'text-red-700',
  ready: 'text-green-700',
}
</script>

<template>
  <div class="bg-slate-100 border-b border-slate-200 flex items-center px-3 py-1 gap-2">
    <button
      class="px-3 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 transition font-medium"
      @click="emit('execute')"
    >
      &#9654; Execute
    </button>

    <button
      class="px-3 py-1 text-xs bg-slate-200 text-slate-800 rounded hover:bg-slate-300 transition font-medium"
      @click="emit('format')"
    >
      &#9889; Format
    </button>

    <div class="ml-auto flex gap-1.5 items-center">
      <span class="inline-block w-2 h-2 rounded-full" :class="dotClass[status.state]" />
      <span class="text-xs font-medium" :class="textClass[status.state]">{{ status.text }}</span>
    </div>
  </div>
</template>
