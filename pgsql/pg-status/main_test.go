package main

import "testing"

func TestHuman(t *testing.T) {
	cases := map[int64]string{
		-1:                     "—",
		0:                      "0B",
		512:                    "512B",
		1024:                   "1.0KiB",
		1536:                   "1.5KiB",
		1024 * 1024:            "1.0MiB",
		3 * 1024 * 1024 * 1024: "3.0GiB",
	}
	for in, want := range cases {
		if got := human(in); got != want {
			t.Errorf("human(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestDuration(t *testing.T) {
	cases := map[int64]string{
		-1:                   "—",
		30:                   "0м",
		90:                   "1м",
		3600:                 "1ч 0м",
		90000:                "1д 1ч 0м",
		2*86400 + 3*3600 + 0: "2д 3ч 0м",
	}
	for in, want := range cases {
		if got := duration(in); got != want {
			t.Errorf("duration(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestEngineLabel(t *testing.T) {
	cases := map[string]string{
		"postgrespro-1c-18":      "Postgres Pro 1c-18",
		"postgrespro-1c-18@5433": "Postgres Pro 1c-18",
		"postgresql@16-main":     "PostgreSQL 16 (main)",
		"postgresql@15-buh":      "PostgreSQL 15 (buh)",
		"weird-unit":             "weird-unit",
	}
	for in, want := range cases {
		if got := engineLabel(in); got != want {
			t.Errorf("engineLabel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUnitBin(t *testing.T) {
	if got := unitBin("postgrespro-1c-17@5433"); got != "/opt/pgpro/1c-17/bin" {
		t.Errorf("unitBin pgpro = %q", got)
	}
	if got := unitBin("postgresql@16-main"); got != "" {
		t.Errorf("unitBin generic = %q, want empty", got)
	}
}
