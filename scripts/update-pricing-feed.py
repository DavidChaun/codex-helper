"""Refresh the OpenAI text token rates in the existing Sparkle feed."""
import json
import re
import sys
from decimal import Decimal
from pathlib import Path
from xml.etree import ElementTree

feed_path = Path("appcast.xml")
feed = feed_path.read_text()
catalog_element = re.compile(r"^ +<codexPricingV1>(.*?)</codexPricingV1>\n", re.M)
previous = catalog_element.search(feed)
rates = json.loads(previous[1]) if previous else {}
updated = 0
for model, row in json.load(sys.stdin, parse_float=Decimal).items():
    if not re.fullmatch(r"gpt-[a-z0-9.-]{1,100}", model):
        continue
    if row.get("litellm_provider") != "openai" or row.get("mode") not in ("chat", "responses"):
        continue
    prices = [row.get(key) for key in (
        "input_cost_per_token", "cache_read_input_token_cost", "output_cost_per_token"
    )]
    if not all(type(price) in (Decimal, int) and 0 < price <= 1 for price in prices):
        continue
    rates[model] = dict(zip(("input", "cached", "output"), (
        float(price * 1_000_000) for price in prices
    )))
    updated += 1

if not updated:
    raise SystemExit("Pricing catalog contains no valid OpenAI GPT text rates")
line = json.dumps(rates, sort_keys=True, separators=(",", ":"), allow_nan=False)
if len(rates) > 2048 or len(line) > 262144:
    raise SystemExit("Pricing catalog exceeds client limits")
head, item, rest = catalog_element.sub("", feed).partition("        <item>\n")
if not item:
    raise SystemExit("Missing appcast item")
revision = head + item + f"            <codexPricingV1>{line}</codexPricingV1>\n" + rest
ElementTree.fromstring(revision)
feed_path.write_text(revision)
