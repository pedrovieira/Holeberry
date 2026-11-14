# Widget freshness labels

Research date: 2026-11-11. Scope: Apple widget guidance and first-party examples relevant to Holeberry's small macOS widget. This is a qualitative comparison, not a prevalence survey.

## Apple guidance

Apple's current Human Interface Guidelines recommend considering a data-update time when people may check a widget more frequently than it can refresh. They also favor focused, glanceable content and balanced information density. A timestamp is conditional guidance, not required widget chrome. [Widgets HIG](https://developer.apple.com/design/human-interface-guidelines/widgets?changes=_3)

WidgetKit extensions do not run continuously. Refresh scheduling is system-managed and affected by visibility and other factors; a requested refresh time is not a guaranteed fresh-data time. [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

The older WWDC20 design talk advises avoiding phrases such as “last updated” and “last checked” when presenting chronological information. That is a real difference in wording from the current HIG. The practical interpretation here is to follow current conditional guidance on freshness and keep the presentation terse. This interpretation is a design judgment; Apple does not explicitly reconcile the two sources. [Design great widgets, transcript near the end](https://developer.apple.com/videos/play/wwdc2020/10103/)

System date views can change their displayed date/time without fetching a new timeline entry. That can support an age cue, subject to checking the precise style and wording in the actual widget. [Displaying dynamic dates](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates)

## First-party app examples

| App / evidence | Observed presentation | Limits |
| --- | --- | --- |
| Things: [official widget support](https://culturedcode.com/things/support/articles/2803567/) and its [Mac desktop screenshot](https://culturedcode.com/frozen/2023/09/hero-sonoma-io65.jpg) | Task list widgets show task content, list headings and controls, without a refresh timestamp in the pictured widgets. | Visual observation of a published macOS Sonoma screenshot, not a claim about every widget version. |
| Fantastical: [Mac widget help](https://flexibits.com/fantastical/help/widgets-and-extensions) and [official calendar/event widget image](https://flexibits.com/img/fantastical/widgets/dark/event-list-calendar@2x.png) | The image prioritizes calendar dates, event times and actions, without a refresh timestamp. Mac documentation confirms the Event List + Calendar category exists on macOS. | Promotional image is cross-platform; it is not proof that every Mac variant looks identical. |
| Apple's Calendar and Weather in the supplied Mac screenshot | Neither pictured small widget shows a refresh timestamp. | User-provided screenshot, not a survey of Apple's widgets or states. |

These examples establish that a permanent refresh label is not universal. They do not establish a numerical rate or prove that omitting it is best for network monitoring.

## Holeberry recommendation

Keep a quiet freshness cue. Holeberry's “All servers online” header describes an observation of remote servers; an old snapshot can appear to promise current availability. This gives freshness a stronger purpose than in a calendar or task-list widget. The displayed time should continue to represent the successful data observation, rather than merely the latest render or refresh attempt.

Consider shortening the cue to an age such as “5 min ago” and including date context for old data. The current hour/minute-only wording cannot distinguish a same-day observation from one made on a previous day. This is a proposal, not an implementation change. A stale-data state should also avoid presenting an old health observation as current.
