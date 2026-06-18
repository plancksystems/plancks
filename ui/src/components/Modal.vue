<script setup>
const props = defineProps({
  title: String,
})
const emit = defineEmits(['close'])
</script>

<template>
  <Teleport to="body">
    <div class="fixed inset-0 z-50 flex items-center justify-center" @mousedown.self="emit('close')">
      <div class="fixed inset-0 bg-black/30" />
      <div class="relative bg-white rounded-lg shadow-xl border border-slate-200 w-full max-w-md mx-4">
        <div class="flex items-center justify-between px-4 py-3 border-b border-slate-200">
          <h3 class="text-sm font-semibold text-slate-800">{{ title }}</h3>
          <button class="text-slate-400 hover:text-slate-600 text-lg leading-none" @click="emit('close')">&times;</button>
        </div>
        <div class="p-4">
          <slot />
        </div>
        <div class="flex justify-end gap-2 px-4 py-3 border-t border-slate-100 bg-slate-50 rounded-b-lg">
          <slot name="footer" />
        </div>
      </div>
    </div>
  </Teleport>
</template>
