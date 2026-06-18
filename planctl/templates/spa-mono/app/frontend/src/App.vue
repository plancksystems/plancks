<script setup>
import { RouterView } from 'vue-router'
</script>

<template>
  <nav class="bg-white border-b border-slate-200 px-6 py-3 shadow-sm">
    <span class="text-lg font-bold text-blue-700">⚡ SPA App</span>
  </nav>
  <main class="flex-1 max-w-3xl mx-auto w-full p-6">
    <RouterView />
  </main>
</template>
