<script setup>
import { ref } from 'vue'
import Modal from './Modal.vue'

const props = defineProps({
  serviceName: String,
})
const emit = defineEmits(['close', 'created'])

const storeName = ref('')
const description = ref('')
const loading = ref(false)
const error = ref('')

async function onSubmit() {
  if (!storeName.value.trim()) {
    error.value = 'Store name is required'
    return
  }
  loading.value = true
  error.value = ''

  try {
    const resp = await fetch('/api/schema', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        action: 'create-store',
        service: props.serviceName,
        ns: storeName.value.trim(),
        description: description.value.trim(),
      }),
    })
    const data = await resp.json()
    if (data.success) {
      emit('created')
      emit('close')
    } else {
      error.value = data.error || 'Failed to create store'
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <Modal title="Create Store" @close="emit('close')">
    <div class="space-y-3">
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">Store Name *</label>
        <input
          v-model="storeName"
          type="text"
          class="w-full px-3 py-1.5 text-sm border border-slate-300 rounded focus:outline-none focus:border-blue-500"
          placeholder="e.g. customers"
          @keydown.enter="onSubmit"
          autofocus
        />
      </div>
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">Description</label>
        <input
          v-model="description"
          type="text"
          class="w-full px-3 py-1.5 text-sm border border-slate-300 rounded focus:outline-none focus:border-blue-500"
          placeholder="Optional description"
        />
      </div>
      <p v-if="error" class="text-xs text-red-600">{{ error }}</p>
    </div>

    <template #footer>
      <button
        class="px-3 py-1.5 text-xs bg-slate-200 text-slate-700 rounded hover:bg-slate-300"
        @click="emit('close')"
      >Cancel</button>
      <button
        class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
        :disabled="loading"
        @click="onSubmit"
      >{{ loading ? 'Creating...' : 'Create' }}</button>
    </template>
  </Modal>
</template>
