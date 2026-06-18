
export async function getSystemDbStatus() {
  const resp = await fetch('/api/system-db/status')
  return resp.json()
}

export async function connectSystemDb(key, uid = 'admin') {
  const resp = await fetch('/api/system-db/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `key=${encodeURIComponent(key)}&uid=${encodeURIComponent(uid)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Connection failed')
  return data
}

export async function logoutSystemDb() {
  const resp = await fetch('/api/system-db/logout', { method: 'POST' })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Logout failed')
  return data
}


export async function fetchDatabases() {
  const resp = await fetch('/api/databases')
  return resp.json()
}

export async function connectDb(serviceName, uid, key) {
  const resp = await fetch('/api/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `service=${encodeURIComponent(serviceName)}&uid=${encodeURIComponent(uid)}&key=${encodeURIComponent(key)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Connection failed')
  return data
}

export async function disconnectDb(serviceName) {
  const resp = await fetch('/api/disconnect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `service=${encodeURIComponent(serviceName)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Disconnect failed')
  return data
}

export async function fetchLeftPane(serviceName) {
  const resp = await fetch(`/api/left-pane?service=${encodeURIComponent(serviceName)}`)
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to load schema')
  return data
}

export async function fetchMonitorData(serviceName) {
  const params = new URLSearchParams()
  if (serviceName) params.set('service', serviceName)
  const url = params.toString() ? `/api/monitor?${params}` : '/api/monitor'
  const resp = await fetch(url)
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to fetch monitor data')
  return {
    history: data.history || [],
    current: data.current || null,
    vlogs: data.vlogs || [],
    cpu_percent: data.cpu_percent ?? null,
    rss_mb: data.rss_mb ?? null,
    cpu_time_us: data.cpu_time_us ?? null,
    process_history: data.process_history || [],
  }
}

export async function dropSchema(action, ns, serviceName) {
  const resp = await fetch('/api/schema', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `action=${encodeURIComponent(action)}&ns=${encodeURIComponent(ns)}&service=${encodeURIComponent(serviceName)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Operation failed')
  return data
}

async function adminPost(params) {
  const resp = await fetch('/api/admin', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&'),
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Operation failed')
  return data
}

export async function listUsers(serviceName) {
  return adminPost({ action: 'list-users', service: serviceName })
}

export async function createUser(serviceName, username, role, key) {
  const params = { action: 'create-user', service: serviceName, username, role }
  if (key) params.key = key
  return adminPost(params)
}

export async function deleteUser(serviceName, username) {
  return adminPost({ action: 'delete-user', service: serviceName, username })
}

export async function updateUser(serviceName, username, role) {
  return adminPost({ action: 'update-user', service: serviceName, username, role })
}

export async function regenerateKey(serviceName, username) {
  return adminPost({ action: 'regenerate-key', service: serviceName, username })
}

export async function listBackups(serviceName) {
  return adminPost({ action: 'list-backups', service: serviceName })
}

export async function createBackup(serviceName, backupPath) {
  return adminPost({ action: 'create-backup', service: serviceName, backup_path: backupPath })
}

export async function restoreBackup(serviceName, backupPath, targetPath) {
  return adminPost({ action: 'restore-backup', service: serviceName, backup_path: backupPath, target_path: targetPath })
}

export async function deleteBackup(serviceName, name, backupPath) {
  return adminPost({ action: 'delete-backup', service: serviceName, name, backup_path: backupPath })
}

export async function listSnapshots(serviceName, rootPath) {
  return adminPost({ action: 'list-snapshots', service: serviceName, backup_path: rootPath })
}

export async function createSnapshot(serviceName, rootPath, name) {
  return adminPost({ action: 'create-snapshot', service: serviceName, backup_path: rootPath, name: name || '' })
}

export async function restoreSnapshot(serviceName, snapshotDir, targetPath) {
  return adminPost({ action: 'restore-snapshot', service: serviceName, backup_path: snapshotDir, target_path: targetPath })
}

export async function getConfig(serviceName) {
  return adminPost({ action: 'get-config', service: serviceName })
}

export async function setConfig(serviceName, configObj) {
  return adminPost({ action: 'set-config', service: serviceName, config: JSON.stringify(configObj) })
}

export async function setServerMode(serviceName, mode) {
  return adminPost({ action: 'set-mode', service: serviceName, mode })
}

export async function demoteServer(serviceName) {
  return adminPost({ action: 'demote', service: serviceName })
}

export async function promoteServer(serviceName) {
  return adminPost({ action: 'promote', service: serviceName })
}

export async function listSchedules(serviceName) {
  return adminPost({ action: 'list-schedules', service: serviceName })
}

export async function createSchedule(serviceName, { name, task_type, cron_expr, enabled, backup_path, description }) {
  const params = { action: 'create-schedule', service: serviceName, name, task_type, cron_expr, enabled }
  if (backup_path) params.backup_path = backup_path
  if (description) params.description = description
  return adminPost(params)
}

export async function updateSchedule(serviceName, { name, task_type, cron_expr, enabled, backup_path, description }) {
  const params = { action: 'update-schedule', service: serviceName, name, task_type, cron_expr, enabled }
  if (backup_path) params.backup_path = backup_path
  if (description) params.description = description
  return adminPost(params)
}

export async function deleteSchedule(serviceName, name) {
  return adminPost({ action: 'delete-schedule', service: serviceName, name })
}

export async function runGC(serviceName, vlogIds) {
  const resp = await fetch('/api/monitor/gc', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `service=${encodeURIComponent(serviceName)}&vlogs=${encodeURIComponent(vlogIds.join(','))}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'GC failed')
  return data
}


export async function fetchServices() {
  const resp = await fetch('/api/services')
  const data = await resp.json()
  if (!resp.ok) throw new Error(data.error || `Server error (${resp.status})`)
  if (data.success === false) throw new Error(data.error || 'Failed to load services')
  return Array.isArray(data) ? data : []
}

async function deployPost(params) {
  const resp = await fetch('/api/deploy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  })
  const text = await resp.text()
  let data
  try {
    data = JSON.parse(text)
  } catch {
    throw new Error(text || `Server error (${resp.status})`)
  }
  if (!data.success) {
    const err = data.error
    throw new Error(typeof err === 'string' ? err : err?.message || JSON.stringify(err) || 'Operation failed')
  }
  return data
}

export async function deployService({ app, name, config_yaml, admin_uid, admin_key, description, port }) {
  return deployPost({ action: 'deploy', app, name, config_yaml, admin_uid, admin_key, description, port })
}

export async function updateWasm(name, wasmFile) {
  const buf = await wasmFile.arrayBuffer()
  const bytes = new Uint8Array(buf)
  let binary = ''
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  const base64 = btoa(binary)
  return deployPost({
    action: 'update-wasm',
    name,
    wasm_filename: wasmFile.name,
    wasm_data: base64,
  })
}

export async function undeployService(name) {
  return deployPost({ action: 'undeploy', name })
}

export async function startService(name) {
  return deployPost({ action: 'start', name })
}

export async function stopService(name) {
  return deployPost({ action: 'stop', name })
}

export async function restartService(name) {
  return deployPost({ action: 'restart', name })
}



export async function fetchAppBackups(appName) {
  const data = await adminPost({ action: 'list-backups', app: appName })
  try {
    return JSON.parse(data.data || '[]')
  } catch {
    return []
  }
}

export async function createAppBackup(appName, outputDir) {
  return adminPost({
    action: 'create-backup',
    app: appName,
    backup_path: outputDir || '',
  })
}

export async function deleteAppBackup(backupPath) {
  return adminPost({ action: 'delete-backup', backup_path: backupPath })
}

export async function fetchServiceBackups(serviceName) {
  return fetchAppBackups(serviceName)
}
export async function createServiceBackup(serviceName, backupPath) {
  return createAppBackup(serviceName, backupPath)
}
export async function deleteServiceBackup(_serviceName, backupPath) {
  return deleteAppBackup(backupPath)
}


export async function fetchWbSchedules() {
  const resp = await fetch('/api/schedules')
  return resp.json()
}

async function wbSchedulePost(params) {
  const resp = await fetch('/api/schedules', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Operation failed')
  return data
}

export async function createWbSchedule(params) {
  return wbSchedulePost({ action: 'create', ...params })
}

export async function updateWbSchedule(params) {
  return wbSchedulePost({ action: 'update', ...params })
}

export async function deleteWbSchedule(name) {
  return wbSchedulePost({ action: 'delete', name })
}

export async function toggleWbSchedule(name) {
  return wbSchedulePost({ action: 'toggle', name })
}


export async function fetchServiceStats(serviceName, limit = 60) {
  const resp = await fetch(`/api/stats?service=${encodeURIComponent(serviceName)}&limit=${limit}`)
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to fetch stats')
  return data.snapshots || []
}


export async function exportManifest(manifest, { service, cron_expr, name, description } = {}) {
  const params = { manifest }
  if (service) params.service = service
  if (cron_expr) params.cron_expr = cron_expr
  if (name) params.name = name
  if (description) params.description = description
  const resp = await fetch('/api/export', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Export failed')
  return data
}

export async function importManifest(manifest, { service, cron_expr, name, description } = {}) {
  const params = { manifest }
  if (service) params.service = service
  if (cron_expr) params.cron_expr = cron_expr
  if (name) params.name = name
  if (description) params.description = description
  const resp = await fetch('/api/import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Import failed')
  return data
}


export async function fetchShellApps() {
  const resp = await fetch('/api/shells')
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to load shell apps')
  return data
}

export async function registerShellApp(name, description, indexHtmlFile) {
  const fd = new FormData()
  fd.append('action', 'register')
  fd.append('name', name)
  fd.append('description', description || '')
  fd.append('index_html', indexHtmlFile)
  const resp = await fetch('/api/shells', { method: 'POST', body: fd })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Registration failed')
  return data
}

export async function updateShellApp(name, indexHtmlFile) {
  const fd = new FormData()
  fd.append('action', 'update')
  fd.append('name', name)
  fd.append('index_html', indexHtmlFile)
  const resp = await fetch('/api/shells', { method: 'POST', body: fd })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Update failed')
  return data
}

export async function deleteShellApp(name) {
  const resp = await fetch('/api/shells', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `action=delete&name=${encodeURIComponent(name)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Delete failed')
  return data
}


export async function fetchApps() {
  const resp = await fetch('/api/apps')
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to load apps')
  return data.apps || []
}

export async function createApp(name, description) {
  const resp = await fetch('/api/apps', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `action=create&name=${encodeURIComponent(name)}&description=${encodeURIComponent(description || '')}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to create app')
  return data
}

export async function deleteApp(name) {
  const resp = await fetch('/api/apps', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `action=delete&name=${encodeURIComponent(name)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || 'Failed to delete app')
  return data
}

export async function shellAppAction(app, action) {
  const resp = await fetch('/api/app-lifecycle', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `action=${encodeURIComponent(action)}&app=${encodeURIComponent(app)}`,
  })
  const data = await resp.json()
  if (!data.success) throw new Error(data.error || `Failed to ${action} shell app`)
  return data
}

export async function executeQuery(query, serviceName) {
  const resp = await fetch('/api/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `query=${encodeURIComponent(query)}&service=${encodeURIComponent(serviceName)}`,
  })
  const text = await resp.text()
  const bytes = new Blob([text]).size
  return { result: JSON.parse(text), bytes }
}
