
async function request(method, path, body) {
  const headers = { 'Accept': 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const res = await fetch(path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}`)
  const ct = res.headers.get('Content-Type') || ''
  return ct.includes('application/json') ? res.json() : res.text()
}

export const api = {
  get:  (p)    => request('GET', p),
  post: (p, b) => request('POST', p, b ?? {}),
  put:  (p, b) => request('PUT',  p, b ?? {}),
  del:  (p)    => request('DELETE', p),
}
