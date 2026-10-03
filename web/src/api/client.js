export const jsonHeaders = { 'Content-Type': 'application/json' };

export function request(url, options = {}) {
  return fetch(url, { credentials: 'same-origin', ...options }).then(async response => {
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(body.error || body.message || `HTTP ${response.status}`);
      error.status = response.status;
      throw error;
    }
    return body;
  });
}
