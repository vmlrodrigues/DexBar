#!/usr/bin/env python3
"""Add or replace one signed GitHub release in DexBar's Sparkle appcast."""

import argparse
import email.utils
import os
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle_tag(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def load_or_create(path: str):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            raise SystemExit(f"{path} has no <channel>")
        return root, channel

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "DexBar"
    return root, channel


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--sig-attrs", required=True)
    parser.add_argument("--min-system", required=True)
    parser.add_argument("--link")
    args = parser.parse_args()

    signature = re.search(r'sparkle:edSignature="([^"]+)"', args.sig_attrs)
    length = re.search(r'length="([^"]+)"', args.sig_attrs)
    if not signature or not length:
        raise SystemExit(f"could not parse sign_update output: {args.sig_attrs!r}")

    root, channel = load_or_create(args.appcast)
    for existing in list(channel.findall("item")):
        existing_version = existing.find(sparkle_tag("shortVersionString"))
        if existing_version is not None and existing_version.text == args.short_version:
            channel.remove(existing)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    if args.link:
        ET.SubElement(item, "link").text = args.link
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=True)
    ET.SubElement(item, sparkle_tag("version")).text = args.version
    ET.SubElement(item, sparkle_tag("shortVersionString")).text = args.short_version
    ET.SubElement(item, sparkle_tag("minimumSystemVersion")).text = args.min_system
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            "type": "application/octet-stream",
            "length": length.group(1),
            sparkle_tag("edSignature"): signature.group(1),
        },
    )

    first_item = channel.find("item")
    insertion_index = list(channel).index(first_item) if first_item is not None else len(list(channel))
    channel.insert(insertion_index, item)

    ET.indent(root, space="  ")
    ET.ElementTree(root).write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast updated: {args.appcast} -> {args.short_version} (build {args.version})")


if __name__ == "__main__":
    main()
