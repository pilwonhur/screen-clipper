# PRD for Screen Clipper

## Motivation and Description
- I use MS Teams, Kakao Talk, Messages frequently.
- My secretaries do not have direct access to them.
- I want my secretaries to read contents from these and reflect them to their secretary work.
- I tried Obsidian web clipper to save each page to Obsidian. However, some contents are not saved properly.

## High-level Design
- Capture the contents of the selected region of screen
- Start from where I set and scroll all the way down to the bottom to capture the contents
- Contents should be texts and images depending on the original content.
- The recorded contents should somehow be handed over to secretaries in Discord.

## Set up
- I will open the app and scroll to the starting point of the page
- Then, I want the clipper to automatically scroll down to the bottom of the page and capture the contents.

## Output
- I don't know how to hand over the contents to secretaries in Discord.
- Figure out the best and easiest way for them to access the contents.

## Implementation
- It should run on macOS