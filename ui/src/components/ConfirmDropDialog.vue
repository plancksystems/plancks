<script setup>
import { ref, computed } from 'vue'
import { dropSchema } from '../api'
import Modal from './Modal.vue'

const props = defineProps({
  type: String,
  ns: String,
  serviceName: String,
})

const emit = defineEmits(['close', 'dropped'])

const confirmText = ref('')
const loading = ref(false)
const error = ref(null)
const isMatch = computed(() => confirmText.value === props.ns)

const actionName = computed(() => `drop-${props.type}`)

async function onConfirm() {
  if (!isMatch.value) return
  loading.value = true
  error.value = null
  try {
    await dropSchema(actionName.value, props.ns, props.serviceName)
    emit('dropped')
    emit('close')
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <Modal :title="`Drop ${type}`" @close="$emit('close')">
    <div class="space-y-3">
      <div class="p-2.5 bg-red-50 border border-red-200 rounded text-xs text-red-700">
        This will permanently drop the {{ type }}
        <code class="bg-red-100 px-1 py-0.5 rounded font-bold">{{ ns }}</code>
        and all its data. This action cannot be undone.
      </div>
      <div v-if="error" class="p-2 bg-red-50 border border-red-200 rounded text-xs text-red-600">{{ error }}</div>
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">
          Type <code class="bg-slate-100 px-1 py-0.5 rounded font-bold">{{ ns }}</code> to confirm
        </label>
        <input
          v-model="confirmText"
          type="text"
          class="w-full px-2 py-1.5 text-xs border rounded focus:outline-none focus:ring-1 font-mono"
          :class="confirmText.length > 0 && !isMatch ? 'border-red-300 focus:ring-red-500' : 'border-slate-300 focus:ring-blue-500'"
          :placeholder="ns"
          autofocus
          @keyup.enter="onConfirm"
        />
      </div>
    </div>
    <template #footer>
      <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="$emit('close')">Cancel</button>
      <button
        class="px-3 py-1.5 text-xs rounded transition"
        :class="isMatch && !loading ? 'bg-red-600 text-white hover:bg-red-700' : 'bg-slate-200 text-slate-400 cursor-not-allowed'"
        :disabled="!isMatch || loading"
        @click="onConfirm"
      >
        {{ loading ? 'Dropping...' : `Drop ${type}` }}
      </button>
    </template>
  </Modal>
</template>
