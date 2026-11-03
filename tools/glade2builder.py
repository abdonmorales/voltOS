#!/usr/bin/env python3
#
# Convert libglade 2 interface files (<glade-interface>) to GtkBuilder
# (<interface>) files that GTK 3 and GTK 2.12+ both load.  Used once to
# bring the OpenSolaris installer's UI files into packages/voltos-gui-install;
# kept for reference and for further imports from the same code base.
#
#   tools/glade2builder.py in.glade out.ui
#
# Handles what that code base uses: <widget> -> <object>, libglade's string
# adjustments (SpinButton, Scrollbar) -> GtkAdjustment objects, combo boxes
# with an "items" list -> GtkComboBoxText, dialog response_id -> action
# widgets, ATK relations and properties, and drops properties GTK 3 removed.
#
# SPDX-License-Identifier: MIT

import sys
import xml.etree.ElementTree as ET

# Properties that GTK 3 removed (or that only libglade understood).
DROP = {
    "GtkWindow": {"allow_shrink", "allow_grow"},
    "GtkDialog": {"has_separator"},
    "GtkTextView": {"text"},
    "GtkProgressBar": {"activity_mode", "bar_style", "discrete_blocks",
                       "activity_step", "activity_blocks", "adjustment"},
    "*": {"response_id"},
}
RENAME = {"tooltip": "tooltip_text"}


def convert(src, dst):
    tree = ET.parse(src)
    root = tree.getroot()
    if root.tag != "glade-interface":
        sys.exit(f"{src}: not a libglade file")
    out = ET.Element("interface")
    req = ET.SubElement(out, "requires", lib="gtk+", version="3.20")
    req.tail = "\n"
    extra = []  # top-level objects created during conversion

    def conv_widget(w, parent_out):
        cls = w.get("class")
        wid = w.get("id")
        obj = ET.SubElement(parent_out, "object", {"class": cls, "id": wid})
        drop = DROP.get(cls, set()) | DROP["*"]
        for el in w:
            if el.tag == "property":
                name = el.get("name")
                if name in drop:
                    if name == "response_id":
                        parent_out.set("_response", el.text or "0")
                    continue
                if name == "adjustment" and cls in (
                        "GtkSpinButton", "GtkHScrollbar", "GtkVScrollbar",
                        "GtkHScale", "GtkVScale"):
                    vals = (el.text or "0 0 0 0 0 0").split()
                    keys = ["value", "lower", "upper", "step_increment",
                            "page_increment", "page_size"]
                    adj = ET.Element("object", {"class": "GtkAdjustment",
                                                "id": wid + "_adjustment"})
                    for k, v in zip(keys, vals):
                        p = ET.SubElement(adj, "property", name=k)
                        p.text = v
                    extra.append(adj)
                    p = ET.SubElement(obj, "property", name="adjustment")
                    p.text = wid + "_adjustment"
                    continue
                if name == "items" and cls == "GtkComboBox":
                    obj.set("class", "GtkComboBoxText")
                    items = ET.SubElement(obj, "items")
                    for line in (el.text or "").split("\n"):
                        if line:
                            it = ET.SubElement(items, "item")
                            if el.get("translatable"):
                                it.set("translatable", "yes")
                            it.text = line
                    continue
                p = ET.SubElement(obj, "property", dict(el.attrib))
                p.set("name", RENAME.get(name, name))
                # Current Pango rejects the old font_desc markup attribute;
                # "font" is the same attribute.
                p.text = el.text.replace('font_desc="', 'font="') \
                    if el.text else el.text
            elif el.tag == "signal":
                ET.SubElement(obj, "signal", dict(el.attrib))
            elif el.tag == "accessibility":
                acc = ET.SubElement(obj, "accessibility")
                for a in el:
                    if a.tag == "atkrelation":
                        ET.SubElement(acc, "relation", type=a.get("type"),
                                      target=a.get("target"))
                    elif a.tag == "atkproperty":
                        # GtkBuilder sets ATK properties on the internal
                        # "accessible" child.
                        ch = obj.find("child[@internal-child='accessible']")
                        if ch is None:
                            ch = ET.SubElement(obj, "child",
                                               {"internal-child": "accessible"})
                            ET.SubElement(ch, "object", {
                                "class": "AtkObject", "id": wid + "-atkobject"})
                        name = a.get("name").replace("_", "-")
                        p = ET.SubElement(ch.find("object"), "property",
                                          name=name)
                        if a.get("translatable"):
                            p.set("translatable", "yes")
                        p.text = a.text
                    elif a.tag == "atkaction":
                        ET.SubElement(acc, "action",
                                      action_name=a.get("action_name"),
                                      description=a.get("description", ""))
                if len(acc) == 0:
                    obj.remove(acc)
            elif el.tag == "child":
                child = ET.SubElement(obj, "child")
                if el.get("internal-child"):
                    child.set("internal-child", el.get("internal-child"))
                for c in el:
                    if c.tag == "widget":
                        conv_widget(c, child)
                    elif c.tag == "placeholder":
                        ET.SubElement(child, "placeholder")
                    elif c.tag == "packing":
                        # libglade marks frame/expander labels with a
                        # "type" packing property; GtkBuilder uses <child
                        # type="label">.
                        t = c.find("property[@name='type']")
                        if t is not None and t.text == "label_item":
                            child.set("type", "label")
                            c.remove(t)
                        if len(c) == 0:
                            continue
                        pk = ET.SubElement(child, "packing")
                        for p in c:
                            q = ET.SubElement(pk, "property", dict(p.attrib))
                            q.text = p.text
        # Buttons with a response id live in a dialog's action area; the
        # dialog (an ancestor) declares them as action widgets.
        return obj

    def walk_actions(obj):
        # Collect _response markers left on <child> elements anywhere below.
        found = []
        for child in obj.iter("child"):
            if "_response" in child.attrib:
                o = child.find("object")
                found.append((child.attrib.pop("_response"), o.get("id")))
        return found

    for w in root.findall("widget"):
        obj = conv_widget(w, out)
        if obj.get("class") == "GtkDialog":
            acts = walk_actions(obj)
            if acts:
                aw = ET.SubElement(obj, "action-widgets")
                for resp, wid in acts:
                    a = ET.SubElement(aw, "action-widget", response=resp)
                    a.text = wid
        else:
            walk_actions(obj)
    for adj in extra:
        out.insert(1, adj)
    ET.indent(out, space="  ")
    with open(src, encoding="utf-8") as f:
        head = f.read().split("<glade-interface>")[0]
    # Keep the licence header comment that precedes <glade-interface>.
    header = head[head.find("<!--"):] if "<!--" in head else ""
    body = ET.tostring(out, encoding="unicode")
    with open(dst, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(header.strip() + "\n" if header else "")
        f.write("<!-- Converted from libglade format by tools/glade2builder.py -->\n")
        f.write(body + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: glade2builder.py in.glade out.ui")
    convert(sys.argv[1], sys.argv[2])
