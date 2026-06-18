<script setup>
import { ref, computed, onMounted } from 'vue'
import { fetchDatabases, fetchServices, fetchApps, fetchLeftPane, startService, stopService, restartService, undeployService, getSystemDbStatus, logoutSystemDb } from './api'
import LoginPage from './components/LoginPage.vue'
import Navbar from './components/Navbar.vue'
import Sidebar from './components/Sidebar.vue'
import QueryWorkspace from './components/QueryWorkspace.vue'
import ServiceView from './components/ServiceView.vue'
import UnifiedDashboard from './components/UnifiedDashboard.vue'
import SchedulesPanel from './components/SchedulesPanel.vue'
import DeployPanel from './components/DeployPanel.vue'
import SettingsPanel from './components/SettingsPanel.vue'
import DocsPanel from './components/DocsPanel.vue'
import ServicesTable from './components/ServicesTable.vue'
import ServerOverviewPanel from './components/ServerOverviewPanel.vue'
import AppView from './components/AppView.vue'

const systemDbConnected = ref(null)
const services = ref([])
const databases = ref([])
const apps = ref([])
const schemas = ref({})
const activeView = ref({ type: 'query' })
const role = ref('standalone')
const wbVersion = ref('')
const queryWorkspaceRef = ref(null)

const queryOpenRequest = ref(null)

const serviceOverviewName = ref(null)

const overviewStores = ref([])

const overviewDbInfo = computed(() =>
  databases.value.find(d => d.name === serviceOverviewName.value)
)
const overviewServiceInfo = computed(() =>
  services.value.find(s => s.name === serviceOverviewName.value)
)

async function openServiceOverview(serviceName) {
  serviceOverviewName.value = serviceName
  appOverviewName.value = null
  overviewStores.value = []
  const db = databases.value.find(d => d.name === serviceName)
  if (db?.connected) {
    try {
      const data = await fetchLeftPane(serviceName)
      overviewStores.value = data.stores || []
    } catch {  }
  }
}

function closeServiceOverview() {
  serviceOverviewName.value = null
  overviewStores.value = []
}

const appOverviewName = ref(null)

const appOverviewInfo = computed(() =>
  apps.value.find(a => a.name === appOverviewName.value)
)

function openAppOverview(appName) {
  appOverviewName.value = appName
  serviceOverviewName.value = null
}

function closeAppOverview() {
  appOverviewName.value = null
}

function onAppOverviewOpenService(svcName) {
  appOverviewName.value = null
  openServiceOverview(svcName)
}

function onOverviewSchemaChanged() {
  if (!serviceOverviewName.value) return
  openServiceOverview(serviceOverviewName.value)
}

onMounted(async () => {
  try {
    const status = await getSystemDbStatus()
    systemDbConnected.value = status.connected
    if (status.role) role.value = status.role
    if (status.version) wbVersion.value = status.version
    if (status.connected) {
      await loadApp()
    }
  } catch {
    systemDbConnected.value = false
  }
})

async function onConnected() {
  systemDbConnected.value = true
  await loadApp()
}

async function onLogout() {
  try {
    await logoutSystemDb()
  } catch {  }
  systemDbConnected.value = false
  services.value = []
  databases.value = []
  schemas.value = {}
  activeView.value = { type: 'query' }
  serviceOverviewName.value = null
}

async function loadApp() {
  await Promise.all([loadServices(), loadDatabases(), loadApps()])
}

async function loadServices() {
  try {
    services.value = await fetchServices()
  } catch {
    services.value = []
  }
}

async function loadDatabases() {
  try {
    databases.value = await fetchDatabases()
  } catch {
    databases.value = []
  }
}

async function loadApps() {
  try {
    apps.value = await fetchApps()
  } catch {
    apps.value = []
  }
}

function onNavigate(view) {
  if (view.type === 'query' && view.service) {
    activeView.value = { type: 'query' }
    queryOpenRequest.value = { serviceName: view.service, appName: view.app || null, storeNs: view.storeNs, _ts: Date.now() }
    loadServices()
    loadDatabases()
    return
  }
  activeView.value = view
  loadServices()
  loadDatabases()
}

function isConnected(serviceName) {
  const db = databases.value.find(d => d.name === serviceName)
  return db?.connected === true
}

const busyServices = ref({})

async function onServiceAction(action) {
  busyServices.value = { ...busyServices.value, [action.name]: action.type }
  try {
    if (action.type === 'start') await startService(action.name)
    else if (action.type === 'stop') await stopService(action.name)
    else if (action.type === 'restart') await restartService(action.name)
    else if (action.type === 'undeploy') await undeployService(action.name)
    await Promise.all([loadServices(), loadDatabases(), loadApps()])
  } catch (e) {
    alert(`${action.type} failed: ${e.message}`)
  } finally {
    const { [action.name]: _, ...rest } = busyServices.value
    busyServices.value = rest
  }
}

function onRefreshDatabases() {
  loadDatabases()
}

async function onLoadSchema(serviceName) {
  if (!isConnected(serviceName)) return
  try {
    const data = await fetchLeftPane(serviceName)
    schemas.value = { ...schemas.value, [serviceName]: { stores: data.stores || [] } }
  } catch {
    schemas.value = { ...schemas.value, [serviceName]: { stores: [] } }
  }
}

function onConnectService({ serviceName }) {
  activeView.value = { type: 'query' }
  queryOpenRequest.value = { serviceName, _ts: Date.now() }
}

const showSidebar = computed(() =>
  !serviceOverviewName.value && !appOverviewName.value && (activeView.value.type === 'query' || activeView.value.type === 'service')
)

const hasAnyAdmin = computed(() =>
  systemDbConnected.value === true || databases.value.some(d => d.role === 'admin')
)
</script>

<template>
  <div v-if="systemDbConnected === null" class="min-h-screen bg-slate-50 flex items-center justify-center">
    <p class="text-slate-400 text-sm">Loading...</p>
  </div>

  <LoginPage v-else-if="!systemDbConnected" @connected="onConnected" />

  <div v-else class="flex flex-col h-screen">
    <Navbar :role="role" :active-view="activeView" :is-admin="hasAnyAdmin" @navigate="onNavigate" @logout="onLogout" />

    <div class="flex flex-1 min-h-0">
      <Sidebar
        v-if="showSidebar"
        :services="services"
        :databases="databases"
        :apps="apps"
        :schemas="schemas"
        :active-view="activeView"
        :role="role"
        :is-admin="hasAnyAdmin"
        @navigate="onNavigate"
        @connect-service="onConnectService"
        @load-schema="onLoadSchema"
        @open-overview="openServiceOverview"
        @open-app-overview="openAppOverview"
        @refresh="loadApp"
      />

      <AppView
        v-if="appOverviewName"
        :app-name="appOverviewName"
        :app-info="appOverviewInfo"
        :services="services"
        @close="closeAppOverview"
        @open-service="onAppOverviewOpenService"
      />

      <ServerOverviewPanel
        v-if="serviceOverviewName"
        :stores="overviewStores"
        :service-name="serviceOverviewName"
        :db-name="serviceOverviewName"
        :role="overviewDbInfo?.role || ''"
        :service-status="overviewServiceInfo?.status || ''"
        :show-back="true"
        :connected-uid="overviewDbInfo?.uid || ''"
        @schema-changed="onOverviewSchemaChanged"
        @service-action="onServiceAction"
        @close="closeServiceOverview"
      />

      <QueryWorkspace
        v-show="activeView.type === 'query' && !serviceOverviewName && !appOverviewName"
        ref="queryWorkspaceRef"
        :services="services"
        :databases="databases"
        :open-request="queryOpenRequest"
        @refresh-databases="onRefreshDatabases"
        @schema-loaded="(name, stores) => schemas = { ...schemas, [name]: { stores } }"
        @navigate="onNavigate"
      />

      <ServicesTable
        v-if="activeView.type === 'services' && !serviceOverviewName && !appOverviewName"
        :services="services"
        :databases="databases"
        :apps="apps"
        :role="role"
        :is-admin="hasAnyAdmin"
        :busy-services="busyServices"
        @navigate="onNavigate"
        @service-action="onServiceAction"
        @refresh="loadApp"
        @open-overview="openServiceOverview"
      />

      <ServiceView
        v-else-if="activeView.type === 'service' && !serviceOverviewName && !appOverviewName"
        :service-name="activeView.service"
        :service-info="services.find(s => s.name === activeView.service)"
        :databases="databases"
        :view="activeView.view || 'query'"
        :store-ns="activeView.storeNs || null"
        @refresh-databases="onRefreshDatabases"
        @schema-loaded="(name, stores) => schemas = { ...schemas, [name]: { stores } }"
        @service-action="onServiceAction"
        @navigate="onNavigate"
      />

      <UnifiedDashboard
        v-else-if="activeView.type === 'dashboard'"
      />

      <SchedulesPanel
        v-else-if="activeView.type === 'schedules'"
      />

      <DeployPanel
        v-else-if="activeView.type === 'deploy'"
        :apps="apps"
        @navigate="onNavigate"
        @apps-changed="loadApps"
      />

      <SettingsPanel
        v-else-if="activeView.type === 'settings'"
        :role="role"
        :version="wbVersion"
      />

      <DocsPanel
        v-else-if="activeView.type === 'docs'"
      />
    </div>
  </div>
</template>
