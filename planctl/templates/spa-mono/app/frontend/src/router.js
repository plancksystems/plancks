import { createRouter, createWebHistory } from 'vue-router'
import Tasks from './pages/Tasks.vue'

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: Tasks },
  ],
})
