<script setup>
import { BookOpen, Settings, LayoutDashboard, Calendar, Server, Terminal, LogOut } from 'lucide-vue-next'

defineProps({
  role: { type: String, default: 'standalone' },
  activeView: Object,
  isAdmin: { type: Boolean, default: false },
})

const emit = defineEmits(['navigate', 'logout'])
</script>

<template>
  <header class="h-10 bg-blue-600 text-white flex items-center px-4 gap-1 shrink-0">
    <span class="text-sm font-bold tracking-wide">Planck</span>
    <span class="text-[10px] text-blue-200 font-medium">Workbench</span>
    <span
      v-if="role !== 'standalone'"
      class="text-[10px] px-1.5 py-0.5 rounded font-medium ml-1"
      :class="role === 'command' ? 'bg-blue-500/40 text-blue-100' : 'bg-amber-500/40 text-amber-100'"
    >
      {{ role }}
    </span>

    <div class="flex-1" />

    <button
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'query' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'query' })"
    >
      <Terminal :size="12" />
      Query
    </button>
    <button
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'services' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'services' })"
    >
      <Server :size="12" />
      Services
    </button>
    <button
      v-if="isAdmin"
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'dashboard' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'dashboard' })"
    >
      <LayoutDashboard :size="12" />
      Dashboard
    </button>
    <button
      v-if="isAdmin"
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'schedules' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'schedules' })"
    >
      <Calendar :size="12" />
      Schedules
    </button>
    <button
      v-if="isAdmin"
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'settings' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'settings' })"
    >
      <Settings :size="12" />
      Settings
    </button>
    <button
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 transition-colors"
      :class="activeView?.type === 'docs' ? 'bg-blue-700 text-white' : 'text-blue-100 hover:text-white hover:bg-blue-500/40'"
      @click="emit('navigate', { type: 'docs' })"
    >
      <BookOpen :size="12" />
      PQL Ref
    </button>
    <div class="w-px h-4 bg-blue-400/40 mx-1" />
    <button
      class="px-2.5 py-1 text-[11px] rounded flex items-center gap-1.5 text-blue-200 hover:text-white hover:bg-blue-500/40 transition-colors"
      @click="emit('logout')"
    >
      <LogOut :size="12" />
      Logout
    </button>
  </header>
</template>
