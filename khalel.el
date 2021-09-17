;;; khalel.el --- description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Hanno Perrey
;;
;; Author: Hanno Perrey <http://gitlab.com/hperrey>
;; Maintainer: Hanno Perrey <hanno@hoowl.se>
;; Created: september 10, 2021
;; Modified: september 10, 2021
;; Version: 0.0.1
;; Keywords: event, calendar, ics, khal
;; Homepage: https://gitlab.com/hperrey/khalel
;; Package-Requires: ((emacs 27.1) (cl-lib "0.5") (org 9.5))
;;
;; This file is not part of GNU Emacs.
;;
;;    This program is free software: you can redistribute it and/or modify
;;    it under the terms of the GNU General Public License as published by
;;    the Free Software Foundation, either version 3 of the License, or
;;    (at your option) any later version.
;;
;;    This program is distributed in the hope that it will be useful,
;;    but WITHOUT ANY WARRANTY; without even the implied warranty of
;;    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;    GNU General Public License for more details.
;;
;;    You should have received a copy of the GNU General Public License
;;    along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;;  khalel provides helper routines to import upcoming events from a local
;;  calendar through khal and to capture new events that are exported to
;;  khal.
;;
;;  The local calendar can be synced with other external tools such as vdirsyncer.
;;
;;  First steps/quick start:
;;  - install and configure khal
;;  - customize the values for default calendar, capture file and import file for khalel
;;  - call `khalel-add-capture-template' to set up a capture template
;;  - consider adding the import org file to your org agenda to show upcoming events there
;;  - import upcoming events through `khalel-import-upcoming-events' or create new ones through `org-capture'
;;
;;; Code:

;;;; Requirements

(require 'org)

;;;; Customization

(defgroup khalel nil
  "Calendar import functions using khal."
  :group 'Calendar)

(defcustom khalel-khal-command "khal"
  "The command to run when executing khal.

When set to nil then it will be guessed."
  :group 'khalel
  :type 'string)

(defcustom khalel-default-calendar "privat"
  "The khal calendar to import into by default.

The calendar for a new event can be modified during the capture
process. Set to nil to use the default calendar configured for
khal instead."
  :group 'khalel
  :type 'string)

(defcustom khalel-default-alarm "10"
  "The default alarm before events to use for new events."
  :group 'khalel
  :type 'string)

(defcustom khalel-capture-key "e"
  "The key to use when registering an `org-capture' template via `khalel-add-capture-template'."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-org-file (concat org-directory "calendar.org")
  "The file to import khal calendar entries into.

CAUTION: the file will be overwritten with each import! The
prompt for overwriting the file can be disabled by setting
`khalel-import-org-file-confirm-overwrite' to nil."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-org-file-confirm-overwrite 't
  "When nil, always overwrite the org file into which events are imported.
Otherwise, ask for confirmation."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-time-delta "30d"
  "How many hours, days, or months in the future to consider when import.
Used as DELTA argument to the khal date range."
  :group 'khalel
  :type 'string)

(defcustom khalel-vdirsyncer-command "vdirsyncer"
  "The command to run when executing vdirsyncer.

When set to nil then it will be guessed."
  :group 'khalel
  :type 'string)


;;;; Commands

(defun khalel-import-upcoming-events ()
  "Imports future calendar entries by calling khal externally.

The time delta which determines how far into the future events
are imported is configured through `khalel-import-time-delta'.
CAUTION: The results are imported into the file
`khalel-import-org-file' which is overwritten to avoid adding
duplicate entires already imported previously.

Please note that the resulting org file does not necessarily
include all information contained in the .ics files it is based
on. Khal only supports certain (basic) fields when creating lists.

Examples of missing fields are timezone information, categories,
alarms or settings for repeating events."
  (interactive)
  (let
      ( ;; call khal directly.
       (khal-bin (or khalel-khal-command
                     (executable-find "khal")))
       (dst (generate-new-buffer "khalel-output")))
    (call-process khal-bin nil dst nil "list" "--format"
                  "* {title} {cancelled}\n\
:PROPERTIES:\n:CALENDAR: {calendar}\n\
:LOCATION: {location}\n\
:ID: {uid}\n\
:END:\n\
When: <{start-date-long} {start-time}>-<{end-date-long} {end-time}>\n\
Description: {description}\nURL: {url}\nOrganizer: {organizer}\n\n\
[[elisp:(khalel-edit-calendar-event)][Edit this event]]\
    [[elisp:(progn (khalel-run-vdirsyncer) (khalel-import-upcoming-events))]\
[Sync and update all]]\n"
                  "--day-format" ""
                  "--once" "today" khalel-import-time-delta)
    (save-excursion
      (with-current-buffer dst
        ;; make buffer writeable
        (let ((inhibit-read-only 't))
          (goto-char (point-min))
          (insert "# -*- buffer-read-only: 1; -*-
#+TITLE khalel imported calendar events

*NOTE*: this file has been generated by \
[[elisp:(khalel-import-upcoming-events)][khalel-import-upcoming-events]] \
and /any changes to this document will be lost on the next import/!
Instead, use =khalel-edit-calendar-event= or =khal edit= to edit the \
underlying calendar entries, then re-import them here.

You can use [[elisp:(khalel-run-vdirsyncer)][khalel-run-vdirsyncer]] \
to synchronize with remote calendars.

Consider adding this file to your list of agenda files so that events \
show up there.\n\n")
          ;; cosmetic fix for all-day events w/o end time
          (goto-char (point-min))
          (while (re-search-forward "^\\(SCHEDULED:.*?\\) ->" nil t)
            (replace-match "\\1>" nil nil))
          (write-file khalel-import-org-file khalel-import-org-file-confirm-overwrite)
          (message (format "Imported %d future events from khal into %s"
                           (length (org-map-entries nil nil nil))
                           khalel-import-org-file)))))
    (kill-buffer dst)))


(defun khalel-export-org-subtree-to-calendar ()
  "Exports current subtree as ics file and into an external khal calendar.
An ID will be automatically be created and stored as property of
the subtree. See documentation of `org-icalendar-export-to-ics'
for details of the supported fields.

Note that the UID used in the ics file is based upon but not
identical to the ID of the org entry. Export of imported
entries will likely result in duplicates in the calendar."
  (interactive)
  (save-excursion
    ;; org-icalendar-export-to-ics doesn't reliably export the full event when
    ;; operating on a subtree only; narrowing the buffer, however, works fine
    (org-narrow-to-subtree)
    (let*
        ;; store IDs right away to avoid duplicates
        ((org-icalendar-store-UID 't)
         ;; create events from non-TODO entries with scheduled time
         (org-icalendar-use-scheduled '(event-if-not-todo))
         (khal-bin (or khalel-khal-command
                       (executable-find "khal")))
         (path (file-name-directory
                (buffer-file-name
                 (buffer-base-buffer))))
         (entriescal (org-entry-get nil "calendar"))
         (calendar (or
                    (when (string-match "[^[:blank:]]" entriescal) entriescal)
                    khalel-default-calendar))
         ;; export to ics
         (ics
          (khalel--sanitize-ics (org-icalendar-export-to-ics nil nil 't)))
         ;; call khal import
         (import
          (with-temp-buffer
            (list
             :exit-status
             (if calendar
                 (call-process khal-bin nil t nil
                               "import" "-a" calendar
                               "--batch"
                               (concat path ics))
               (call-process khal-bin nil t nil
                             "import"
                             "--batch"
                             (concat path ics)))
             :output
             (buffer-string)))))
      (widen)
      (when
          (/= 0 (plist-get import :exit-status))
        (message
         (format
          "%s failed importing %s into calendar '%s' and exited with status %d: %s"
          khal-bin
          ics
          calendar
          (plist-get import :exit-status)
          (plist-get import :output)))))))


(defun khalel-add-capture-template (&optional key)
  "Add an `org-capture' template with KEY for creating new events.
If argument is nil then `khalel-capture-key' will be used as
default instead. New events will be captured in a temporary file
and immediately exported to khal."
  (with-eval-after-load 'org
    (add-to-list 'org-capture-templates
                 `(,(or key khalel-capture-key) "calendar event"
                   entry
                   (function khalel--make-temp-file)
                   ,(concat "* %?\nSCHEDULED: %^T\n:PROPERTIES:\n:CREATED: %U\n:CALENDAR: \n\
:CATEGORY: event\n:LOCATION: unknown\n\
:APPT_WARNTIME: " khalel-default-alarm "\n:END:\n" ))))
  (add-hook 'org-capture-before-finalize-hook
            'khalel--capture-finalize-calendar-export))


(defun khalel-run-vdirsyncer ()
  "Run vdirsyncer process to synchronize local calendar entries."
  (interactive)
  (let ((buf "*VDIRSYNCER-OUTPUT-BUFFER*"))
    (with-output-to-temp-buffer buf
        (khalel--make-temp-window buf 16)
        (set-process-sentinel
         (start-process
          "khalel-vdirsyncer-process"
          buf
          (or khalel-vdirsyncer-command
              (executable-find "vdirsyncer"))
          "sync")
         'khalel--delete-process-window-when-done)
        ;; show output
        (sit-for 1)
        (with-current-buffer buf
          (set-window-point
           (get-buffer-window (current-buffer) 'visible)
           (point-min)))
      )))

(defun khalel-edit-calendar-event ()
  "Edit the event at the cursor position using khal's interactive edit command.
Works on imported events and used their ID to search for the
  correct event to modify."
  (interactive)
  (let* ((buf (get-buffer-create "*khal-edit*"))
         (uid (org-entry-get nil "id"))
         (win (khalel--make-temp-window buf 16))
         )
    (if (and uid (string-match "[^[:blank:]]" uid))
        (progn
          (set-process-sentinel
           (get-buffer-process (make-comint-in-buffer "khal-edit" nil khalel-khal-command nil "edit" uid))
           'khalel--delete-process-window-when-done)
          (pop-to-buffer buf))
      (message "khalel: could not find ID associated with current entry."))))

;;;; Functions
(defun khalel--make-temp-file ()
  "Create and visit a temporary file for capturing and exporting events."
  (find-file (make-temp-file "khalel-capture" nil ".org")))

(defun khalel--capture-finalize-calendar-export ()
  "Export current event capture.
To be added as hook to `org-capture-before-finalize-hook'."
  (let ((key  (plist-get org-capture-plist :key))
        (desc (plist-get org-capture-plist :description)))
    (when (and (not org-note-abort) (equal key khalel-capture-key))
      (khalel-export-org-subtree-to-calendar))))

(defun khalel--sanitize-ics (ics)
  "Remove modifications to data in ICS file.

When exporting, `org-icalendar-export-to-ics' changes an entry's
ID and summary depending on the type of date (deadline, scheduled
or active/inactive timestamp) was discovered.

While this ensures unique UIDs when multiple dates exist in an
org entry, this is undesired when e.g. modifying events imported
through khal. For scheduled events as created by
`khalel-import-upcoming-events', these modifications are
therefore removed."
  (with-temp-file ics
    (insert-file-contents ics)
    ;; remove any prefix added to the UID by org-icalendar-export-to-ics
    ;; so that we can edit and re-export events without creating duplicates
    (goto-char (point-min))
    (while (re-search-forward "^\\(UID:[[:blank:]]*\\)SC-" nil t)
      (replace-match "\\1" nil nil))
    (goto-char (point-min))
    ;; remove prefix to summary for scheduled events
    (while (re-search-forward "^\\(SUMMARY:[[:blank:]]*\\)S: " nil t)
      (replace-match "\\1" nil nil)))
  ics)

(defun khalel--make-temp-window (buf height)
  "Create a temporary window with HEIGHT at the bottom of the frame to display buffer BUF."
  (or (get-buffer-window buf 'visible)
      (let ((win
             (split-window
              (frame-root-window)
              (- (window-height (frame-root-window)) height))))
        (set-window-buffer win buf)
        (set-window-dedicated-p win t)
        win)))

(defun khalel--delete-process-window-when-done (process event)
  "Check status of PROCESS at each EVENT and delete window after process finished."
  (let ((buf (process-buffer process)))
    (when (= 0 (process-exit-status process))
      (when (get-buffer buf)
        (with-current-buffer buf
          (set-window-point
           (get-buffer-window (current-buffer) 'visible)
           (point-max)))
        (sit-for 2)
        (delete-window (get-buffer-window buf))
        (kill-buffer buf)))))

;;;; Footer
(provide 'khalel)
;;; khalel.el ends here
