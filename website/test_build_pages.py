"""Tests for build_pages.py:  python3 -m unittest discover -s website -p 'test_*.py'"""
import json
import os
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_pages  # noqa: E402
from build_pages import build, main, nearest, publish  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "website"
LEGAL = ROOT / "web"
NS = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}


def stops(n=6):
    base = [
        {"id": "65000", "name": "València-Estació del Nord", "lat": 39.4669, "lon": -0.3772, "nucleos": ["40"]},
        {"id": "64200", "name": "Silla", "lat": 39.3620, "lon": -0.4150, "nucleos": ["40"]},
        {"id": "69110", "name": "Gandia", "lat": 38.9705, "lon": -0.1798, "nucleos": ["40"]},
        {"id": "79600", "name": "Sant Adrià & Besòs", "lat": 41.4250, "lon": 2.2160, "nucleos": ["51"]},
        {"id": "05761", "name": "Cistierna", "lat": 42.80, "lon": -5.12, "nucleos": ["47", "60"]},
        {"id": "99001", "name": "Bad</script><b>'\"", "lat": 40.0, "lon": -3.0, "nucleos": ["10"]},
    ]
    return base[:n]


def write_data(tmp, st=None):
    d = Path(tmp) / "data"
    (d / "feeds").mkdir(parents=True)
    nucleos = [{"id": "10", "name": "Madrid"}, {"id": "40", "name": "Valencia"}, {"id": "47", "name": "León"},
               {"id": "51", "name": "Rodalies de Catalunya"}, {"id": "60", "name": "Bilbao"}]
    for n in nucleos:
        n["feed"] = f"feeds/{n['id']}.json"
        (d / n["feed"]).write_text(json.dumps({"nucleo": n["id"], "trips": []}))
    (d / "index.json").write_text(json.dumps({"version": 2, "generated_at": "2026-11-26T02:30:09Z",
                                              "nucleos": nucleos, "stops": stops() if st is None else st}))
    return d


def ld_json(page: str) -> dict:
    m = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
    return json.loads(m.group(1))


class NearestTest(unittest.TestCase):
    def test_nearest_excludes_itself_sorted_by_distance(self):
        st = stops()
        out = nearest(st[0], st, 2)
        self.assertEqual([s["id"] for s, _ in out], ["64200", "69110"])


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = write_data(self.tmp.name)
        self.env = Path(self.tmp.name) / "web.env"
        self.env.write_text("CONTACT_NAME=Ana & Co\nCONTACT_EMAIL=hola@example.com\n")
        self.out = Path(self.tmp.name) / "build"
        build(self.data, SITE / "index.html", LEGAL, self.env, self.out, min_count=1)

    def tearDown(self):
        self.tmp.cleanup()

    def page(self, sid):
        return (self.out / "estacion" / f"{sid}.html").read_text(encoding="utf-8")

    def test_one_page_per_station_with_title_canonical_and_heading(self):
        self.assertEqual(sorted(p.stem for p in (self.out / "estacion").iterdir()), sorted(s["id"] for s in stops()))
        p = self.page("65000")
        self.assertIn("<title>València-Estació del Nord — próximos trenes y andén | Andén</title>", p)
        self.assertIn("Próximos trenes desde València-Estació del Nord (Valencia): andén, retrasos y cancelaciones "
                      "en tiempo real, cada 30 segundos. Gratis y sin registro.", p)
        self.assertIn('<link rel="canonical" href="https://andenapp.com/estacion/65000">', p)
        self.assertIn('<h1 class="station">València-Estació del Nord</h1>', p)
        self.assertIn('<aside id="extra" class="extra" data-path="/estacion/65000">', p)
        self.assertEqual(p.count("<title>"), 1)
        self.assertNotIn("<!--seo:", p)
        self.assertIn('<script type="module" src="/js/app.js"></script>', p)

    def test_names_are_escaped_in_html_and_json_ld(self):
        p = self.page("99001")
        self.assertNotIn("Bad</script>", p)
        self.assertIn("Bad&lt;/script&gt;&lt;b&gt;&#x27;&quot;", p)
        self.assertEqual(ld_json(p)["name"], "Bad</script><b>'\"")
        a = self.page("79600")
        self.assertIn("Sant Adrià &amp; Besòs", a)
        self.assertEqual(ld_json(a)["name"], "Sant Adrià & Besòs")

    def test_json_ld_is_a_train_station_with_geo(self):
        d = ld_json(self.page("64200"))
        self.assertEqual((d["@type"], d["identifier"], d["url"]), ("TrainStation", "64200", "https://andenapp.com/estacion/64200"))
        self.assertEqual(d["geo"], {"@type": "GeoCoordinates", "latitude": 39.362, "longitude": -0.415})

    def test_nearby_links_and_a_to_z_link(self):
        p = self.page("65000")
        extra = p[p.index('<aside id="extra"'):]
        links = re.findall(r'href="/estacion/([0-9]{5})"', extra)
        self.assertEqual(links[:2], ["64200", "69110"])
        self.assertNotIn("65000", links)
        self.assertIn('href="/estaciones"', extra)
        self.assertRegex(extra, r"\d+(,\d)? (m|km)")

    def test_station_in_two_nucleos_one_page(self):
        p = self.page("05761")
        self.assertIn("Cistierna (León, Bilbao)", p)

    def test_a_to_z_lists_every_station_grouped_by_letter(self):
        p = (self.out / "estaciones.html").read_text(encoding="utf-8")
        self.assertEqual(sorted(re.findall(r'href="/estacion/([0-9]{5})"', p)), sorted(s["id"] for s in stops()))
        self.assertIn('<link rel="canonical" href="https://andenapp.com/estaciones">', p)
        self.assertIn('<h2 id="S">S</h2>', p)
        self.assertIn("Sant Adrià &amp; Besòs", p)
        self.assertNotIn("<style", p)

    def test_a_to_z_accented_names_sort_with_their_letter(self):
        with tempfile.TemporaryDirectory() as tmp:
            st = [{"id": "00001", "name": "Álora", "lat": 36.8, "lon": -4.7, "nucleos": ["10"]},
                  {"id": "00002", "name": "Alpedrete", "lat": 40.5, "lon": -3.4, "nucleos": ["10"]},
                  {"id": "00003", "name": "Bilbao", "lat": 43.3, "lon": -2.9, "nucleos": ["60"]}]
            out = Path(tmp) / "b"
            build(write_data(tmp, st), SITE / "index.html", LEGAL, Path(tmp) / "x.env", out, min_count=1)
            p = (out / "estaciones.html").read_text(encoding="utf-8")
            self.assertLess(p.index("Álora"), p.index("Alpedrete"))
            self.assertLess(p.index("Álora"), p.index('<h2 id="B">'))

    def test_sitemap_lists_home_pages_and_every_station(self):
        root = ET.parse(self.out / "sitemap.xml").getroot()
        locs = [u.find("s:loc", NS).text for u in root.findall("s:url", NS)]
        self.assertEqual(locs[:4], ["https://andenapp.com/", "https://andenapp.com/estaciones",
                                    "https://andenapp.com/privacidad", "https://andenapp.com/ayuda"])
        self.assertEqual(len(locs), 4 + len(stops()))
        lastmods = {u.find("s:loc", NS).text: getattr(u.find("s:lastmod", NS), "text", None) for u in root.findall("s:url", NS)}
        self.assertEqual(lastmods["https://andenapp.com/estacion/65000"], "2026-11-26")
        self.assertIsNone(lastmods["https://andenapp.com/"])

    def test_stations_json_for_search(self):
        st = json.loads((self.out / "stations.json").read_text(encoding="utf-8"))
        self.assertEqual(st[0], {"id": "99001", "name": "Bad</script><b>'\"", "lat": 40.0, "lon": -3.0, "nucleo": "Madrid"})
        self.assertEqual([s["name"] for s in st][1:3], ["Cistierna", "Gandia"])
        self.assertEqual(next(s for s in st if s["id"] == "05761")["nucleo"], "León, Bilbao")

    def test_legal_pages_rendered_with_contact_env(self):
        p = (self.out / "privacidad.html").read_text(encoding="utf-8")
        self.assertIn("Ana &amp; Co", p)
        self.assertIn('<a href="mailto:hola@example.com">hola@example.com</a>', p)
        a = (self.out / "ayuda.html").read_text(encoding="utf-8")
        self.assertIn('href="/privacidad"', a)
        self.assertNotIn('href="privacidad.html"', a)
        self.assertIn('<link rel="canonical" href="https://andenapp.com/ayuda">', a)
        self.assertTrue((self.out / "legal.css").read_text())

    def test_legal_pages_have_no_inline_style(self):
        for name in ("privacidad.html", "ayuda.html"):
            p = (self.out / name).read_text(encoding="utf-8")
            self.assertNotIn("<style", p)
            self.assertNotIn("style=", p)
            self.assertIn('href="/legal.css"', p)


class LegalFallbackTest(unittest.TestCase):
    def test_legal_pages_fallback_without_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "b"
            build(write_data(tmp), SITE / "index.html", LEGAL, Path(tmp) / "missing.env", out, min_count=1)
            p = (out / "privacidad.html").read_text(encoding="utf-8")
            self.assertNotIn("${", p)
            self.assertNotIn("mailto:", p)


class RefuseTest(unittest.TestCase):
    def run_build(self, tmp, st=None, template=SITE / "index.html", min_count=1):
        build(write_data(tmp, st), template, LEGAL, Path(tmp) / "none.env", Path(tmp) / "b", min_count=min_count)

    def test_refuses_too_few_stations(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            self.run_build(tmp, min_count=800)

    def test_refuses_template_without_markers(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            t = Path(tmp) / "index.html"
            t.write_text("<html><head></head><body></body></html>")
            self.run_build(tmp, template=t)

    def test_refuses_invalid_station(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            self.run_build(tmp, st=stops() + [{"id": "../x", "name": "N", "lat": 1, "lon": 1, "nucleos": ["10"]}])

    def test_refuses_repeated_station(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            self.run_build(tmp, st=stops() + [stops()[0]])


class PublishTest(unittest.TestCase):
    def run_main(self, tmp, min_count="1"):
        data = Path(tmp) / "data"
        if not data.exists():
            write_data(tmp)
        return main(["--data", str(data), "--site", str(SITE), "--legal", str(LEGAL),
                     "--contact-env", str(Path(tmp) / "none.env"), "--out", str(Path(tmp) / "web"),
                     "--min-count", min_count])

    def test_publish_swaps_a_symlink_and_keeps_one_previous_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            for _ in range(3):
                self.assertEqual(self.run_main(tmp), 0)
            self.assertTrue(web.is_symlink())
            self.assertTrue((web / "estacion" / "65000.html").exists())
            builds = [p for p in Path(tmp).iterdir() if p.name.startswith("web-")]
            self.assertEqual(len(builds), 2)
            self.assertIn(web.resolve(), [b.resolve() for b in builds])

    def test_failed_build_leaves_published_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            self.assertEqual(self.run_main(tmp), 0)
            before = os.readlink(web)
            self.assertEqual(self.run_main(tmp, min_count="800"), 1)
            self.assertEqual(os.readlink(web), before)
            self.assertEqual(len([p for p in Path(tmp).iterdir() if p.name.startswith("web-")]), 1)

    def test_cleanup_failure_keeps_the_new_build_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            for _ in range(2):
                self.assertEqual(self.run_main(tmp), 0)
            real = build_pages.shutil.rmtree

            def broken(path, *a, **kw):
                if kw.get("ignore_errors"):
                    return real(path, *a, **kw)
                raise PermissionError("no")
            build_pages.shutil.rmtree = broken
            try:
                self.assertEqual(self.run_main(tmp), 0)
            finally:
                build_pages.shutil.rmtree = real
            self.assertTrue((web / "estacion" / "65000.html").exists())

    def test_out_parent_created_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_data(tmp)
            out = Path(tmp) / "new" / "current"
            self.assertEqual(main(["--data", str(Path(tmp) / "data"), "--site", str(SITE), "--legal", str(LEGAL),
                                   "--contact-env", str(Path(tmp) / "none.env"), "--out", str(out), "--min-count", "1"]), 0)
            self.assertTrue((out / "estacion" / "65000.html").exists())

    def test_publish_refuses_a_plain_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp) / "web"
            web.mkdir()
            with self.assertRaises(ValueError):
                publish(Path(tmp) / "web-x", web)


if __name__ == "__main__":
    unittest.main()
