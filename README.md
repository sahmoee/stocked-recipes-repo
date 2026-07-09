# Recipe Feed Manager (GUI)

A single Swift file that opens a macOS window to manage your Stocked recipe feed and its
GitHub repo — like BuildBuddy, with buttons.

## Run

Put the files in your `stocked-recipes` folder (the one with `recipes.json`), then
double-click **Launch Recipe Manager.command**, or run `swift RecipeManager.swift`.

## Buttons

Recipes
- **Rebuild** — pulls DummyJSON + TheMealDB A-Z, merges ALL your custom*.json files,
  fills any missing images. Full replace.
- **Add N New** — type a number, then adds only recipes NOT already listed, up to N.
  (Detects what's already in the feed and skips it.)
- **Add Recipe** — a form; saved to recipes.json and custom_recipes.json.
- **Fill Images** — finds photos for any recipes missing one (TheMealDB, then a
  category food photo).
- **Validate** — titles, steps, ingredient/measure counts, duplicates, missing images.
- **Drag & drop** — drop one or more .json files onto the window to import their recipes
  (new ones added; each dropped file is also kept as its own custom_<name>.json).

GitHub
- **GitHub Login** — opens Terminal for `gh auth login`.
- **Connect Repo** — inits git + creates/connects the repo.
- **Commit & Push** — commits and pushes (sets upstream automatically on first push).
- **Pull** — git pull --rebase.
- **Branch / Merge** — shows the current branch; type a branch name and press **Merge**
  to merge it into the current branch.
- **Verify** — checks recipes.json, git repo, GitHub login, remote; prints the feed URL.

## Multiple custom files

Any file named `custom*.json` in the folder is merged on Rebuild — so you can keep several
(e.g. custom_desserts.json, custom_family.json). Dropped files become custom_<name>.json.

## Requirements
macOS Swift toolchain (Xcode / Command Line Tools) and `gh` (`brew install gh`).
