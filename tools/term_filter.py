"""term_filter.py -- what counts as a term, in one place.

`build_glossary.py` decides which of the game's strings become glossary terms, and
`tools/suggest_terms.py` looks for terms the glossary is missing. If each carried its own copy of the
rules the two would drift apart within a release, and a "candidate" the builder would reject would
keep showing up as work to do. The rules live here instead.
"""
from __future__ import annotations

import re

# Words that must never become terms, however often the game uses them.
#
# Masking replaces a term everywhere it appears, which is right for a name - "Relic" is 圣物 in every
# context - and wrong for a word that carries grammar or has a second, ordinary meaning. The settings
# export this project collected offered On, Off, All, None, Back, Save, Close, In, Out, More, Name,
# Type, Value..., and a glossary built from those would rewrite "on the ground" as the word a UI shows
# for a switch, or "close range" as the word a menu shows for a button. That corruption is silent:
# the placeholder and format-specifier guards cannot see meaning.
#
# So this list is about *function*: state words, prepositions, verbs that double as directions, and
# generic nouns that are labels for other things. Nouns and names are the point of the glossary and
# stay - "filters" was reported as mistranslated and is deliberately not here.
STOP_WORDS = {
    # state and choice
    'on', 'off', 'all', 'none', 'auto', 'automatic', 'default', 'yes', 'no', 'ok', 'true', 'false',
    'enabled', 'disabled', 'unavailable', 'available', 'always', 'never', 'optional', 'required',
    'selected', 'unselected', 'unknown', 'mixed', 'custom',
    # actions a label performs (verbs, and several of them are also directions)
    'apply', 'cancel', 'close', 'back', 'next', 'previous', 'open', 'save', 'load', 'delete',
    'add', 'edit', 'remove', 'reset', 'clear', 'confirm', 'continue', 'retry', 'skip', 'start',
    'stop', 'exit', 'quit', 'search', 'sort', 'order', 'select', 'choose', 'show', 'hide',
    'toggle', 'enable', 'disable', 'set', 'change', 'use', 'copy', 'paste', 'move',
    # place and direction
    'left', 'right', 'top', 'bottom', 'up', 'down', 'in', 'out', 'inside', 'outside', 'above',
    'below', 'front', 'rear', 'near', 'far', 'here', 'there', 'over', 'under',
    # quantity and degree
    'more', 'less', 'max', 'min', 'maximum', 'minimum', 'low', 'medium', 'high', 'normal',
    'small', 'large', 'big', 'short', 'long', 'fast', 'slow', 'new', 'old', 'first', 'last',
    # generic nouns that exist to label other things
    'name', 'title', 'text', 'value', 'values', 'type', 'types', 'size', 'mode', 'modes', 'level',
    'amount', 'number', 'count', 'total', 'info', 'information', 'help', 'about', 'other', 'others',
    'option', 'options', 'setting', 'settings', 'button', 'buttons', 'key', 'keys', 'test',
}

# Weapon mark designations ("Mk VII", "Mk IIa", and the paired "Mk I & Mk V" of the slab shield).
# They arrived with the 2026-09-29 key discovery (loc_weapon_mark_*, 132 keys) and read the same in
# ten of the twelve languages: only zh-cn drops the space ("Mk.VII") and ru spells it out
# ("Мод. VII"). Masking a mark therefore buys nothing a reader would notice and costs 29 entries in
# a table whose job is protecting *names* - the player asked for them to be left out (2026-09-29).
# The keys stay in translations/term_keys.lua, so re-enabling this is one line.
MARK_DESIGNATION = re.compile(
    r'^(?:Mk|MK|Mark)\.?\s*[IVXLivxl0-9]+[a-z]?'
    r'(?:\s*(?:&|and|\+)\s*(?:Mk|MK|Mark)\.?\s*[IVXLivxl0-9]+[a-z]?)?$', re.I)
# Values that are not words a player reads, but records the localization carries: the developers'
# own placeholders ("-- aura description --"), a truncated list entry ("1 more"), a bare mark label
# ("M1") and the lowercase operation ids the Havoc screens use internally ("no quarter", "spy hunt",
# "vox ghosts"). Masking any of those would either do nothing or rewrite ordinary English, and every
# one of them also had no Ukrainian, which is how they were found (2026-09-29).
PLACEHOLDER = re.compile(r'^(?:--.*--|\d+ more|[A-Za-z]?\d+)$')
LOWERCASE_ID = re.compile(r'^[^A-Z]*\s[^A-Z]*$')


def is_term(text: str) -> bool:
    if not text or len(text) < 2 or len(text) > 30:
        return False
    if text[-1] in '.!:;':
        return False
    if MARK_DESIGNATION.match(text) or PLACEHOLDER.match(text) or LOWERCASE_ID.match(text):
        return False
    if re.search(r'[{}%<>|]', text):
        return False
    if re.fullmatch(r'[\d\s.,%+-]+', text):
        return False
    if text.strip().lower() in STOP_WORDS:
        return False
    return True
