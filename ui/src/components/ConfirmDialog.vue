<script setup>
import Modal from './Modal.vue'

const props = defineProps({
  title: { type: String, default: 'Confirm' },
  message: String,
  confirmLabel: { type: String, default: 'Confirm' },
  confirmClass: { type: String, default: 'bg-red-600 hover:bg-red-700' },
  loading: Boolean,
})

const emit = defineEmits(['confirm', 'close'])
</script>

<template>
  <Modal :title="title" @close="emit('close')">
    <p class="text-sm text-slate-600">{{ message }}</p>
    <template #footer>
      <button
        class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded"
        @click="emit('close')"
        :disabled="loading"
      >Cancel</button>
      <button
        class="px-3 py-1.5 text-xs text-white rounded transition"
        :class="confirmClass"
        @click="emit('confirm')"
        :disabled="loading"
      >{{ loading ? 'Working...' : confirmLabel }}</button>
    </template>
  </Modal>
</template>
