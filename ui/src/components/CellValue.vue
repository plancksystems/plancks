<script setup>
defineProps({
  value: null,
})
</script>

<template>
  <span v-if="value === null || value === undefined" class="text-slate-300">-</span>
  <span v-else-if="Array.isArray(value)" class="text-slate-400">Array[{{ value.length }}]</span>
  <span v-else-if="typeof value === 'object'" class="text-slate-400">{...}</span>
  <span v-else class="text-slate-700">{{ String(value) }}</span>
</template>
