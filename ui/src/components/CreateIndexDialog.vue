<script setup>
import { ref } from 'vue'
import Modal from './Modal.vue'

const props = defineProps({
  serviceName: String,
  storeNs: String,
})
const emit = defineEmits(['close', 'created'])

const indexName = ref('')
const field = ref('')
const fieldType = ref('String')
const unique = ref(true)
const description = ref('')
const loading = ref(false)
const error = ref('')

const fieldTypes = ['String', 'U32', 'U64', 'I32', 'I64', 'F32', 'F64', 'Boolean']

async function onSubmit() {
  if (!indexName.value.trim()) {
    error.value = 'Index name is required'
    return
  }
  if (!field.value.trim()) {
    error.value = 'Field name is required'
    return
  }
  loading.value = true
  error.value = ''

  const ns = props.storeNs + '.' + indexName.value.trim()

  try {
    const resp = await fetch('/api/schema', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        action: 'create-index',
        service: props.serviceName,
        ns,
        field: field.value.trim(),
        field_type: fieldType.value,
        unique: String(unique.value),
        description: description.value.trim(),
      }),
    })
    const data = await resp.json()
    if (data.success) {
      emit('created')
      emit('close')
    } else {
      error.value = data.error || 'Failed to create index'
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <Modal title="Create Index" @close="emit('close')">
    <div class="space-y-3">
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">Store</label>
        <div class="text-sm text-slate-700 bg-slate-50 px-3 py-1.5 rounded border border-slate-200">{{ storeNs }}</div>
      </div>
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">Index Name *</label>
        <input
          v-model="indexName"
          type="text"
          class="w-full px-3 py-1.5 text-sm border border-slate-300 rounded focus:outline-none focus:border-blue-500"
          placeholder="e.g. idx_email"
          @keydown.enter="onSubmit"
          autofocus
        />
        <p class="text-[10px] text-slate-400 mt-0.5">Full namespace: {{ storeNs }}.{{ indexName || '...' }}</p>
      </div>
      <div>
        <label class="block text-xs font-medium text-slate-600 mb-1">Field *</label>
        <input
          v-model="field"
          type="text"
          class="w-full px-3 py-1.5 text-sm border border-slate-300 rounded focus:outline-none focus:border-blue-500"
          placeholder="e.g. email"
        />
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Field Type</label>
          <select
            v-model="fieldType"
            class="w-full px-3 py-1.5 text-sm border border-slate-300 rounded focus:outline-none focus:border-blue-500 bg-white"
          >
            <option v-for="ft in fieldTypes" :key="ft" :value="ft">{{ ft }}</option>
          </select>
        </div>
        <div class="flex items-end pb-1">
          <label class="flex items-center gap-2 cursor-pointer">
            <input v-model="unique" type="checkbox" class="rounded border-slate-300" />
            <span class="text-xs text-slate-600">Unique</span>
          </label>
        </div>
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
