<script setup>
import { ref, watch, computed } from 'vue'
import {
  Server, ChevronRight, ChevronDown,
  Table2, Plus, Download, Upload, DatabaseBackup, ListTree,
  Activity, Trash2, BookOpen, Rocket
} from 'lucide-vue-next'
import ContextMenu from './ContextMenu.vue'

const props = defineProps({
  databases: Array,
  selectedDb: Number,
  stores: Array,
  activeView: Object,
  role: { type: String, default: '' },
})

const canWrite = computed(() => props.role === 'admin' || props.role === 'read_write')

const emit = defineEmits(['select-db', 'navigate', 'context-action'])

const expandedDb = ref(null)
const contextMenu = ref(null)

watch(() => props.selectedDb, (idx) => {
  expandedDb.value = idx
}, { immediate: true })

function onServerClick(idx, db) {
  if (expandedDb.value !== idx) {
    expandedDb.value = idx
    emit('select-db', idx)
  }
  emit('navigate', { type: 'server', dbIndex: idx, dbName: db.name })
}

function onMonitorClick() {
  emit('navigate', { type: 'monitor' })
}

function onStoreClick(ns) {
  emit('navigate', { type: 'query', store: ns })
}

function onContextMenu(e, type, data) {
  e.preventDefault()
  e.stopPropagation()

  let items = []
  if (type === 'server') {
    if (canWrite.value) {
      items.push({ label: 'Create Store', icon: Plus, action: { type: 'create-store', db: data } })
    }
    if (props.role === 'admin') {
      if (items.length) items.push({ separator: true })
      items.push({ label: 'Backup', icon: DatabaseBackup, action: { type: 'backup', db: data } })
    }
  } else if (type === 'store') {
    if (canWrite.value) {
      items.push({ label: 'Create Index', icon: ListTree, action: { type: 'create-index', store: data } })
      items.push({ separator: true })
    }
    items.push({ label: 'Export', icon: Download, action: { type: 'export', store: data } })
    if (canWrite.value) {
      items.push({ label: 'Import', icon: Upload, action: { type: 'import', store: data } })
    }
    if (props.role === 'admin') {
      items.push({ separator: true })
      items.push({ label: 'Drop Store', icon: Trash2, danger: true, action: { type: 'drop-store', store: data } })
    }
  }

  contextMenu.value = { x: e.clientX, y: e.clientY, items }
}

function onContextAction(action) {
  emit('context-action', action)
}

function closeContextMenu() {
  contextMenu.value = null
}

function onDocsClick() {
  emit('navigate', { type: 'docs' })
}

function onDeployClick() {
  emit('navigate', { type: 'deploy' })
}

function isActive(type, key) {
  if (!props.activeView) return false
  if (type === 'docs') return props.activeView.type === 'docs'
  if (type === 'deploy') return props.activeView.type === 'deploy'
  if (type === 'server') return props.activeView.type === 'server'
  if (type === 'monitor') return props.activeView.type === 'monitor'
  if (type === 'query') return props.activeView.type === 'query' && props.activeView.store === key
  return false
}
</script>

<template>
  <aside class="w-64 min-w-[16rem] max-w-[16rem] bg-slate-50 text-slate-700 border-r border-slate-200 flex flex-col overflow-hidden">
    <div class="bg-slate-100 border-b border-slate-200 flex items-center px-3 py-2 gap-2">
      <h1 class="text-sm font-bold text-slate-700">Planck</h1>
      <span class="text-xs text-slate-400">Workbench</span>
    </div>

    <div class="flex-1 overflow-y-auto light-scroll">
      <div class="py-2">
        <div
          class="tree-node flex items-center gap-1.5 px-3 py-1 cursor-pointer hover:bg-slate-200/70"
          :class="{ 'bg-blue-50 text-blue-700': isActive('docs') }"
          @click="onDocsClick"
        >
          <BookOpen :size="14" class="text-violet-500 shrink-0" />
          <span class="text-xs font-medium truncate">PQL Reference</span>
        </div>

        <div
          class="tree-node flex items-center gap-1.5 px-3 py-1 cursor-pointer hover:bg-slate-200/70 mb-1"
          :class="{ 'bg-blue-50 text-blue-700': isActive('deploy') }"
          @click="onDeployClick"
        >
          <Rocket :size="14" class="text-orange-500 shrink-0" />
          <span class="text-xs font-medium truncate">Services</span>
        </div>

        <div v-for="(db, idx) in databases" :key="idx" class="tree-root">
          <div
            class="tree-node flex items-center gap-1.5 px-3 py-1 cursor-pointer hover:bg-slate-200/70"
            :class="{ 'bg-blue-50 text-blue-700': isActive('server') }"
            @click="onServerClick(idx, db)"
            @contextmenu="onContextMenu($event, 'server', { idx, name: db.name })"
          >
            <component :is="expandedDb === idx ? ChevronDown : ChevronRight" :size="12" class="text-slate-400 shrink-0" />
            <Server :size="14" class="text-blue-500 shrink-0" />
            <span class="text-xs font-medium truncate">{{ db.name }}</span>
            <span class="text-[10px] text-slate-400 ml-auto shrink-0">{{ db.label }}</span>
          </div>

          <div v-if="expandedDb === idx && selectedDb === idx" class="tree-children tree-l1">
            <div v-if="role === 'admin'" class="tree-branch">
              <div
                class="tree-node flex items-center gap-1.5 pl-7 pr-3 py-1 cursor-pointer hover:bg-slate-200/70"
                :class="{ 'bg-green-50 text-green-700': isActive('monitor') }"
                @click="onMonitorClick"
              >
                <Activity :size="13" class="text-green-500 shrink-0" />
                <span class="text-xs font-medium">Monitor</span>
              </div>
            </div>

            <template v-if="stores">
              <div v-for="store in stores" :key="store.ns" class="tree-branch">
                <div
                  class="tree-node flex items-center gap-1.5 pl-7 pr-3 py-1 cursor-pointer hover:bg-slate-200/70"
                  :class="{ 'bg-blue-50 text-blue-700': isActive('query', store.ns) }"
                  @click="onStoreClick(store.ns)"
                  @contextmenu="onContextMenu($event, 'store', { ns: store.ns, short: store.short })"
                >
                  <Table2 :size="13" class="text-slate-400 shrink-0" />
                  <span class="text-xs truncate text-slate-600">{{ store.short || store.ns }}</span>
                </div>
              </div>
              <p v-if="stores.length === 0" class="text-[10px] text-slate-400 pl-7 py-1">No stores</p>
            </template>
          </div>
        </div>

        <p v-if="databases.length === 0" class="text-slate-500 text-xs px-3 py-2">No servers</p>
      </div>
    </div>

    <ContextMenu
      v-if="contextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      :items="contextMenu.items"
      @action="onContextAction"
      @close="closeContextMenu"
    />
  </aside>
</template>

<style scoped>
.tree-children {
  position: relative;
}
.tree-l1::before {
  content: '';
  position: absolute;
  left: 18px;
  top: 0;
  bottom: 8px;
  border-left: 1px dotted #cbd5e1;
}
.tree-children > .tree-branch > .tree-node::before {
  content: '';
  position: absolute;
  top: 50%;
  height: 0;
  border-top: 1px dotted #cbd5e1;
}
.tree-l1 > .tree-branch > .tree-node::before {
  left: 18px;
  width: 8px;
}
.tree-children .tree-node {
  position: relative;
}
</style>
