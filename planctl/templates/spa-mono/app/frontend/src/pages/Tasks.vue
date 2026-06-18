<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../composables/api.js'

const tasks = ref([])
const newTitle = ref('')

async function load() {
  tasks.value = await api.get('/tasks')
}
async function add() {
  if (!newTitle.value.trim()) return
  await api.post('/tasks', { Title: newTitle.value })
  newTitle.value = ''
  await load()
}
async function toggle(t) {
  await api.put(`/tasks/${t.TaskID}`, { Done: !t.Done })
  await load()
}
async function remove(t) {
  await api.del(`/tasks/${t.TaskID}`)
  await load()
}

onMounted(load)
</script>

<template>
  <header class="flex items-center justify-between mb-4">
    <h1 class="text-2xl font-bold text-slate-800">Tasks</h1>
    <span class="text-xs text-slate-500">{{ tasks.length }} total</span>
  </header>

  <form @submit.prevent="add" class="flex gap-2 mb-4">
    <input v-model="newTitle"
           placeholder="What needs doing?"
           class="flex-1 px-3 py-2 rounded-md border border-slate-200 text-sm" />
    <button class="px-4 py-2 rounded-md bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium">
      Add
    </button>
  </form>

  <p v-if="tasks.length === 0" class="text-slate-400 text-sm text-center py-12">
    No tasks yet — add one above.
  </p>

  <ul v-else class="bg-white rounded-xl border border-slate-200 divide-y divide-slate-100 shadow-sm">
    <li v-for="t in tasks" :key="t.TaskID" class="px-4 py-3 flex items-center gap-3">
      <button @click="toggle(t)"
              :class="['w-5 h-5 rounded border-2 flex items-center justify-center',
                       t.Done ? 'border-emerald-500 bg-emerald-500 text-white' : 'border-slate-300']">
        <span v-if="t.Done">✓</span>
      </button>
      <span :class="['flex-1 text-sm', t.Done ? 'text-slate-400 line-through' : 'text-slate-800']">
        {{ t.Title }}
      </span>
      <button @click="remove(t)" class="text-slate-300 hover:text-red-500">🗑</button>
    </li>
  </ul>
</template>
