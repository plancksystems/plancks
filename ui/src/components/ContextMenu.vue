<script setup>
import { onMounted, onUnmounted } from 'vue'

const props = defineProps({
  x: Number,
  y: Number,
  items: Array,
})

const emit = defineEmits(['close', 'action'])

function onClick(item) {
  if (item.separator) return
  emit('action', item.action)
  emit('close')
}

function onClickOutside(e) {
  const menu = document.querySelector('[data-context-menu]')
  if (menu && menu.contains(e.target)) return
  emit('close')
}

let bound = false
onMounted(() => {
  requestAnimationFrame(() => {
    document.addEventListener('mousedown', onClickOutside)
    document.addEventListener('contextmenu', onClickOutside)
    bound = true
  })
})

onUnmounted(() => {
  if (bound) {
    document.removeEventListener('mousedown', onClickOutside)
    document.removeEventListener('contextmenu', onClickOutside)
  }
})
</script>

<template>
  <Teleport to="body">
    <div
      data-context-menu
      class="fixed z-50 bg-white rounded-lg shadow-lg border border-slate-200 py-1 min-w-[160px] text-sm"
      :style="{ left: x + 'px', top: y + 'px' }"
      @contextmenu.prevent
    >
      <template v-for="(item, i) in items" :key="i">
        <div v-if="item.separator" class="border-t border-slate-100 my-1" />
        <div
          v-else
          class="flex items-center gap-2 px-3 py-1.5 cursor-pointer"
          :class="item.danger
            ? 'text-red-600 hover:bg-red-50 hover:text-red-700'
            : 'text-slate-700 hover:bg-blue-50 hover:text-blue-700'"
          @click.stop="onClick(item)"
        >
          <component v-if="item.icon" :is="item.icon" :size="14" class="shrink-0" />
          <span class="text-xs">{{ item.label }}</span>
        </div>
      </template>
    </div>
  </Teleport>
</template>
