<script setup>
import { ref, computed } from 'vue'
import {
  ChevronRight, ChevronDown, Server, Database, Zap,
  Table2, Settings, Plug, RefreshCw
} from 'lucide-vue-next'

const props = defineProps({
  services: { type: Array, default: () => [] },
  databases: { type: Array, default: () => [] },
  apps: { type: Array, default: () => [] },
  schemas: { type: Object, default: () => ({}) },
  activeView: Object,
  role: { type: String, default: 'standalone' },
  isAdmin: { type: Boolean, default: false },
})

const emit = defineEmits(['navigate', 'connect-service', 'load-schema', 'open-overview', 'open-app-overview', 'refresh'])

const expanded = ref(new Set())

function toggle(key) {
  if (expanded.value.has(key)) expanded.value.delete(key)
  else expanded.value.add(key)
}

function statusDot(status) {
  if (status === 'running') return 'bg-green-500'
  if (status === 'stopped') return 'bg-slate-400'
  if (status === 'crashed') return 'bg-red-500'
  return 'bg-slate-300'
}

function isConnected(serviceName) {
  const db = props.databases.find(d => d.name === serviceName)
  return db?.connected === true
}

function getDbIndex(serviceName) {
  return props.databases.findIndex(db => db.name === serviceName)
}

function getStores(serviceName) {
  return props.schemas[serviceName]?.stores || []
}

function buildServiceSubtree(serviceList) {
  const groups = {}
  const standalone = []
  for (const svc of serviceList) {
    const live = props.services.find(ls => ls.name === svc.name)
    const enriched = live ? { ...svc, ...live } : svc
    if (enriched.name.endsWith('.db.command') || enriched.name.endsWith('.db.query')) {
      const base = enriched.name.replace(/\.(command|query)$/, '')
      if (!groups[base]) groups[base] = {}
      if (enriched.name.endsWith('.db.command')) groups[base].command = enriched
      else groups[base].query = enriched
    } else {
      standalone.push(enriched)
    }
  }
  const tree = []
  for (const [base, nodes] of Object.entries(groups)) {
    tree.push({ type: 'group', base, nodes })
  }
  for (const svc of standalone) {
    tree.push({ type: 'single', svc })
  }
  return tree
}

const serviceTree = computed(() => {
  const tree = []
  for (const app of props.apps) {
    if (app.kind === 'system' && !props.isAdmin) continue
    const subtree = buildServiceSubtree(app.services || [])
    tree.push({
      type: 'app',
      name: app.name,
      description: app.description,
      kind: app.kind,
      children: subtree,
    })
  }
  return tree
})


function onGroupExpand(base) {
  toggle(`grp:${base}`)
}

function onNodeClick(svc) {
  const key = `node:${svc.name}`
  if (expanded.value.has(key)) expanded.value.delete(key)
  else expanded.value.add(key)
  emit('load-schema', svc.name)
}

function onGearClick(svc) {
  emit('open-overview', svc.name)
}

function onAppGearClick(appName) {
  emit('open-app-overview', appName)
}

function onConnectClick(svc) {
  emit('connect-service', { serviceName: svc.name })
}

function onStoreClick(svc, storeNs, appName) {
  emit('navigate', { type: 'query', service: svc.name, app: appName || null, storeNs })
}


function isActiveService(svcName) {
  const v = props.activeView
  return (v?.type === 'query' && v?.service === svcName)
    || (v?.type === 'service' && v?.service === svcName)
}

function isActiveStore(svcName, storeNs) {
  const v = props.activeView
  return (v?.type === 'query' && v?.service === svcName && v?.storeNs === storeNs)
    || (v?.type === 'service' && v?.service === svcName && v?.storeNs === storeNs)
}

function nodeLabel(svcName) {
  if (svcName.endsWith('.db.command')) return 'command'
  if (svcName.endsWith('.db.query')) return 'query'
  return svcName
}

function groupStatus(nodes) {
  const statuses = [nodes.command?.status, nodes.query?.status].filter(Boolean)
  if (statuses.includes('running')) return 'bg-green-500'
  if (statuses.includes('degraded')) return 'bg-yellow-500'
  if (statuses.includes('crashed')) return 'bg-red-500'
  return 'bg-slate-400'
}

function serviceType(svc) {
  return svc.service_type || 'standalone'
}

function serviceIcon(svc) {
  return svc?.kind === 'sse_hub' ? Zap : Database
}

function serviceIconClass(svc) {
  return svc?.kind === 'sse_hub' ? 'text-purple-500 shrink-0' : 'text-amber-500 shrink-0'
}

const WIDTH_KEY = 'wb.sidebarWidth'
const MIN_WIDTH = 180
const MAX_WIDTH = 600
const DEFAULT_WIDTH = 224

function clampWidth(n) {
  if (!Number.isFinite(n)) return DEFAULT_WIDTH
  return Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, Math.round(n)))
}

const width = ref(DEFAULT_WIDTH)
try {
  const saved = Number(localStorage.getItem(WIDTH_KEY))
  if (saved) width.value = clampWidth(saved)
} catch (_) {  }

const isDragging = ref(false)

function onDragStart(e) {
  e.preventDefault()
  isDragging.value = true
  const startX = e.clientX
  const startW = width.value

  function onMove(ev) {
    width.value = clampWidth(startW + (ev.clientX - startX))
  }
  function onEnd() {
    isDragging.value = false
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onEnd)
    try { localStorage.setItem(WIDTH_KEY, String(width.value)) } catch (_) {}
  }
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onEnd)
}
</script>

<template>
  <aside
    class="relative bg-slate-50 border-r border-slate-200 flex flex-col overflow-hidden text-slate-700 shrink-0"
    :style="{ width: width + 'px' }"
    :class="{ 'select-none': isDragging }"
  >
    <div
      class="absolute top-0 right-0 h-full w-1 cursor-col-resize z-20 hover:bg-blue-400/40 transition-colors"
      :class="{ 'bg-blue-500/60': isDragging }"
      @pointerdown="onDragStart"
    />
    <div class="flex-1 overflow-y-auto light-scroll">
      <div v-if="serviceTree.length > 0" class="px-1 pb-2 pt-2">
        <template v-for="item in serviceTree" :key="item.type + ':' + (item.name || item.base || item.svc?.name)">

          <template v-if="item.type === 'app'">
            <div class="mb-1">
              <div
                class="flex items-center gap-1 px-1.5 py-1 hover:bg-slate-200/70 rounded cursor-pointer select-none group"
                @click="toggle(`app:${item.name}`)"
              >
                <component
                  :is="expanded.has(`app:${item.name}`) ? ChevronDown : ChevronRight"
                  :size="12" class="text-slate-400 shrink-0"
                />
                <span class="text-[11px] font-semibold text-slate-600 truncate flex-1">{{ item.name }}</span>
                <button
                  class="p-0.5 rounded text-slate-400 hover:text-slate-600 hover:bg-slate-300/50 opacity-0 group-hover:opacity-100 transition-opacity shrink-0"
                  title="App settings + backups"
                  @click.stop="onAppGearClick(item.name)"
                >
                  <Settings :size="11" />
                </button>
                <span class="text-[9px] text-slate-400">{{ (item.children || []).length }}</span>
              </div>

              <div v-if="expanded.has(`app:${item.name}`)" class="ml-2">
                <template v-for="child in item.children" :key="child.type + ':' + (child.base || child.svc?.name)">
                  <template v-if="child.type === 'group'">
                    <div class="mb-0.5">
                      <div
                        class="flex items-center gap-1 px-1.5 py-1 hover:bg-slate-200/70 rounded cursor-pointer select-none"
                        @click="onGroupExpand(child.base)"
                      >
                        <component :is="expanded.has(`grp:${child.base}`) ? ChevronDown : ChevronRight" :size="12" class="text-slate-400 shrink-0" />
                        <Server :size="13" class="text-blue-500 shrink-0" />
                        <span class="text-xs font-medium truncate flex-1">{{ child.base }}</span>
                        <span class="w-1.5 h-1.5 rounded-full shrink-0" :class="groupStatus(child.nodes)" />
                      </div>
                      <div v-if="expanded.has(`grp:${child.base}`)" class="ml-3">
                        <template v-for="nodeKey in ['command', 'query']" :key="nodeKey">
                          <template v-if="child.nodes[nodeKey]">
                            <div class="mb-0.5">
                              <div
                                class="flex items-center gap-1 px-1.5 py-1 hover:bg-slate-200/70 rounded cursor-pointer group"
                                :class="{ 'bg-blue-50': isActiveService(child.nodes[nodeKey].name) }"
                                @click.stop="onNodeClick(child.nodes[nodeKey])"
                              >
                                <component :is="expanded.has(`node:${child.nodes[nodeKey].name}`) ? ChevronDown : ChevronRight" :size="11" class="text-slate-400 shrink-0" />
                                <Database :size="12" class="text-amber-500 shrink-0" />
                                <span class="text-[11px] font-medium truncate">{{ nodeKey }}</span>
                                <div class="ml-auto flex items-center gap-0.5 shrink-0">
                                  <button class="p-0.5 rounded hover:bg-slate-300/50 shrink-0 transition-opacity" :class="isConnected(child.nodes[nodeKey].name) ? 'text-green-500 opacity-100' : 'text-slate-400 hover:text-blue-500 opacity-0 group-hover:opacity-100'" @click.stop="onConnectClick(child.nodes[nodeKey])"><Plug :size="11" /></button>
                                  <button class="p-0.5 rounded text-slate-400 hover:text-slate-600 hover:bg-slate-300/50 opacity-0 group-hover:opacity-100 transition-opacity shrink-0" @click.stop="emit('refresh')"><RefreshCw :size="11" /></button>
                                  <button class="p-0.5 rounded text-slate-400 hover:text-slate-600 hover:bg-slate-300/50 opacity-0 group-hover:opacity-100 transition-opacity shrink-0" @click.stop="onGearClick(child.nodes[nodeKey])"><Settings :size="11" /></button>
                                </div>
                                <span class="w-1.5 h-1.5 rounded-full shrink-0" :class="statusDot(child.nodes[nodeKey].status)" />
                              </div>
                              <div v-if="expanded.has(`node:${child.nodes[nodeKey].name}`)" class="ml-6">
                                <template v-if="getStores(child.nodes[nodeKey].name).length > 0">
                                  <div v-for="store in getStores(child.nodes[nodeKey].name)" :key="store.ns" class="flex items-center gap-1 px-1.5 py-0.5 hover:bg-slate-200/70 rounded cursor-pointer" :class="{ 'bg-blue-50 text-blue-700': isActiveStore(child.nodes[nodeKey].name, store.ns) }" @click.stop="onStoreClick(child.nodes[nodeKey], store.ns, item.name)">
                                    <Table2 :size="11" class="text-green-500 shrink-0" />
                                    <span class="text-[11px] truncate">{{ store.short || store.ns.split('.').pop() }}</span>
                                  </div>
                                </template>
                                <p v-else-if="isConnected(child.nodes[nodeKey].name)" class="text-[10px] text-slate-400 px-2 py-1">No stores</p>
                                <p v-else class="text-[10px] text-slate-400 px-2 py-1">Not connected</p>
                              </div>
                            </div>
                          </template>
                        </template>
                      </div>
                    </div>
                  </template>

                  <template v-else-if="child.type === 'single'">
                    <div class="mb-0.5">
                      <div
                        class="flex items-center gap-1 px-1.5 py-1 hover:bg-slate-200/70 rounded cursor-pointer group"
                        :class="{ 'bg-blue-50': isActiveService(child.svc.name) }"
                        @click.stop="onNodeClick(child.svc)"
                      >
                        <component :is="expanded.has(`node:${child.svc.name}`) ? ChevronDown : ChevronRight" :size="11" class="text-slate-400 shrink-0" />
                        <component :is="serviceIcon(child.svc)" :size="13" :class="serviceIconClass(child.svc)" />
                        <span class="text-[11px] font-medium truncate flex-1">{{ child.svc.service_name || child.svc.name }}</span>
                        <div class="ml-auto flex items-center gap-0.5 shrink-0">
                          <button v-if="child.svc.kind !== 'sse_hub'" class="p-0.5 rounded hover:bg-slate-300/50 shrink-0 transition-opacity" :class="isConnected(child.svc.name) ? 'text-green-500 opacity-100' : 'text-slate-400 hover:text-blue-500 opacity-0 group-hover:opacity-100'" @click.stop="onConnectClick(child.svc)"><Plug :size="11" /></button>
                          <button v-if="child.svc.kind !== 'sse_hub'" class="p-0.5 rounded text-slate-400 hover:text-slate-600 hover:bg-slate-300/50 opacity-0 group-hover:opacity-100 transition-opacity shrink-0" @click.stop="onGearClick(child.svc)"><Settings :size="11" /></button>
                        </div>
                        <span class="w-1.5 h-1.5 rounded-full shrink-0" :class="statusDot(child.svc.status)" />
                      </div>
                      <div v-if="expanded.has(`node:${child.svc.name}`)" class="ml-6">
                        <template v-if="getStores(child.svc.name).length > 0">
                          <div v-for="store in getStores(child.svc.name)" :key="store.ns" class="flex items-center gap-1 px-1.5 py-0.5 hover:bg-slate-200/70 rounded cursor-pointer" :class="{ 'bg-blue-50 text-blue-700': isActiveStore(child.svc.name, store.ns) }" @click.stop="onStoreClick(child.svc, store.ns, item.name)">
                            <Table2 :size="11" class="text-green-500 shrink-0" />
                            <span class="text-[11px] truncate">{{ store.short || store.ns.split('.').pop() }}</span>
                          </div>
                        </template>
                        <p v-else-if="isConnected(child.svc.name)" class="text-[10px] text-slate-400 px-2 py-1">No stores</p>
                        <p v-else class="text-[10px] text-slate-400 px-2 py-1">Not connected</p>
                      </div>
                    </div>
                  </template>
                </template>
              </div>
            </div>
          </template>

        </template>
      </div>
      <p v-else class="text-[10px] text-slate-400 px-3 py-2">No services deployed</p>
    </div>
  </aside>
</template>
