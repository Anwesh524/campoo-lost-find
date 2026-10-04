# Decisions

Findr, a campus Lost & Found app. Made by Anwesh for GDG USAR.

## 1. Problem: Lost & Found
Losing a phone, ID card or wallet on campus is common, and the usual fix is a
message in a crowded group chat. A focused app with one feed, search and
filters solves that one problem well, so I chose it over broader ideas like
events or clubs.

## 2. One primary flow: report, get matched, reunite
Everything serves one flow: post what you lost or found, get alerted when
something matches, and mark the item reunited. Secondary screens (alerts,
map, profile) support that flow and don't compete with it.

## 3. Rule-based match alerts
When a report is posted, it is compared with open reports of the opposite
type in the same category that share a keyword or location. A match creates an
alert for the other owner. It is simple and explainable and works without a
server. AI image matching is a later step.

## 4. Reputation computed from outcomes
The helper rating comes from real actions (found items that were marked
reunited), not from manual stars, so it can't be inflated. Points and levels
(Newcomer, Helper, Campus Hero, Legend) reward helping others.

## 5. Urgent posts and rewards, without in-app payments
A lost item can be marked urgent and carry an optional reward (Rs 1 to 50,000).
Urgent and rewarded posts rank first in the feed. Payments are deliberately left
out: the owner pays the finder directly, which avoids handling money and
fraud or refund liability in a prototype.

## 6. Campus-scoped feeds with a college picker
Students care about items lost on their own campus, so the app asks for a
college on first launch (like delivery apps ask for an address) and shows only
that campus's feed. Adding another college is a data change, not a rewrite.

## 7. In-app campus map instead of a Google Maps hand-off
Campus areas and walkways are modelled as a graph (nodes with positions in
metres, edges as paths). Dijkstra finds the shortest walk and bearings between
segments become instructions like "turn right and walk 25 m". It works offline,
needs no API key, and stays inside the app.

## 8. One-time profile capture
Name, department and contact are asked once and reused to greet the user, pre-fill
the contact field on every report and populate the profile. This removes repeated
typing from the main flow.

## 9. Flutter, built local-first and then moved to Firebase
Flutter gives one codebase and fast UI iteration. I first built everything on
local storage (shared_preferences) to validate the flow, then moved to a cloud
backend once the app worked.

## 10. Firebase: Firestore plus anonymous auth, protected by security rules
Lost & Found only works if everyone shares one feed, so posts live in Firestore
with real-time listeners. Anonymous auth gives each device a user id with no
sign-up friction. Rules let any signed-in user read posts, but only the owner can
edit or delete one, and alerts can only be read by the user they are addressed to.

## 11. Photos stored as compressed base64
Photos are resized to about 600 px and stored in the post document. This avoids
needing Firebase Storage (which can require a paid plan) while staying under the
1 MB document limit.

## Known limitations and next steps
- The campus map layout and distances are placeholders and need to be surveyed on
  the real USAR campus.
- Anonymous ids reset if the app is uninstalled; Google Sign-In is the next step.
- Alerts appear inside the app. Alerts while the app is closed need Firebase
  Cloud Messaging and a small server function.
- Alert creation rules are prototype-level and should be tightened with a server
  function for production.