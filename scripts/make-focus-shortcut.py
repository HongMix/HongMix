#!/usr/bin/env python3
"""Builds Resources/HongMix Focus.shortcut (Do Not Disturb on/off for FocusGuard.swift).

Input text "on" -> Do Not Disturb on, "off" -> off, anything else -> no change.
Output: the current Focus name ("" when no Focus is on).

Usage (Shortcuts only imports signed files; signing uses the Apple ID signed in on this Mac):
  python3 scripts/make-focus-shortcut.py /tmp/unsigned.shortcut
  shortcuts sign --mode anyone --input /tmp/unsigned.shortcut --output "Resources/HongMix Focus.shortcut"
"""
import plistlib, uuid, sys
def act(i, **p): return {"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": p}
g1, g2, u, tx = (str(uuid.uuid4()).upper() for _ in range(4))
ext = {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}
inp = {"Value": {"Type": "ActionOutput", "OutputUUID": tx, "OutputName": "Text"}, "WFSerializationType": "WFTextTokenAttachment"}
# Identifier only: a DisplayString ("Do Not Disturb") makes the action look the mode up by its English name, which fails on a Korean Mac.
dnd = {"Identifier": "com.apple.donotdisturb.mode.default"}
actions = [
 act("is.workflow.actions.detect.text", UUID=tx, WFInput=ext),
 act("is.workflow.actions.conditional", GroupingIdentifier=g1, WFControlFlowMode=0, WFCondition=4, WFConditionalActionString="on", WFInput={"Type": "Variable", "Variable": inp}),
 act("is.workflow.actions.dnd.set", Enabled=1, FocusModes=dnd, AssertionType="Turned Off"),
 act("is.workflow.actions.conditional", GroupingIdentifier=g1, WFControlFlowMode=1),
 act("is.workflow.actions.conditional", GroupingIdentifier=g2, WFControlFlowMode=0, WFCondition=4, WFConditionalActionString="off", WFInput={"Type": "Variable", "Variable": inp}),
 act("is.workflow.actions.dnd.set", Enabled=0, FocusModes=dnd),
 act("is.workflow.actions.conditional", GroupingIdentifier=g2, WFControlFlowMode=2),
 act("is.workflow.actions.conditional", GroupingIdentifier=g1, WFControlFlowMode=2),
 act("is.workflow.actions.dnd.getfocus", UUID=u),
 act("is.workflow.actions.output", WFOutput={"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ActionOutput", "OutputUUID": u, "OutputName": "Focus"}}}, "WFSerializationType": "WFTextTokenString"}),
]
wf = {"WFWorkflowActions": actions, "WFWorkflowClientVersion": "2302.0.4", "WFWorkflowMinimumClientVersion": 900,
      "WFWorkflowMinimumClientVersionString": "900",
      "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59446},
      "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
      "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"], "WFWorkflowHasShortcutInputVariables": True}
plistlib.dump(wf, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
