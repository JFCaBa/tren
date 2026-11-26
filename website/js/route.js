// URL → page: "/" home, "/estacion/65000" (optional trailing slash) a station.

export function parseRoute(pathname) {
  if (pathname === '/' || pathname === '') return { page: 'home' };
  const m = /^\/estacion\/([0-9]{5})\/?$/.exec(pathname);
  if (!m) return { page: 'notfound' };
  return { page: 'station', id: m[1], canonical: `/estacion/${m[1]}` };
}

// The server-built <aside id="extra" data-path="…"> (nearby stations, A–Z link) belongs to one
// page: after in-app navigation to another page it would be stale.
export function extraBelongs(dataPath, pathname) {
  if (!dataPath) return false;
  const here = parseRoute(pathname);
  const mine = parseRoute(dataPath);
  if (here.page !== mine.page) return false;
  return here.page !== 'station' || here.id === mine.id;
}
