;;; ob-elasticsearch.el --- org-babel functions for Elasticsearch queries

;; Copyright (C) 2014 Bjarte Johansen
;; Copyright (C) 2014 Matthew Lee Hinman

;; Author: Bjarte Johansen
;; Keywords: literate programming, reproducible research
;; Homepage: http://www.github.com/dakrone/es-mode
;; Version: 1.0.0

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Provides a way to evaluate Elasticsearch queries in org-mode.

;;; Code:
(require 'ob)
(require 'es-mode)
(require 'es-parse)
(require 's)

(defcustom es-jq-path "jq"
  "Location of the `jq' tool"
  :group 'es
  :type 'string)

(defvar org-babel-tangle-lang-exts)
(add-to-list 'org-babel-tangle-lang-exts '("es" . "es"))

(defun es-org-aget (key alist)
  (cdr (assoc (intern key) alist)))

(defun org-babel-expand-body:es (body params)
  "This command is used by org-tangle to create a file with the
source code of the elasticsearch block. If :tangle specifies a
file with the .sh extension a curl-request is created instead of
just a normal .es file that contains the body of the block.."
  (let ((ext (file-name-extension
              (cdr (assoc :tangle params))))
        (body (s-format body 'es-org-aget
                        (mapcar (lambda (x)
                                  (when (eq (car x) :var)
                                    (cdr x)))
                                params))))
    (if (not (equal "sh" ext))
        body
      (let ((method (cdr (assoc :method params)))
            (url (cdr (assoc :url params))))
        (format "curl -X%s %s -d %S\n"
                (upcase method)
                url
                body)))))

(defun es-org--parse-headers (headers-arg)
  (when headers-arg
    (mapcar (lambda (value)
              (when (string-match "^\\([^= \f\t\n\r\v]+\\)[ \t]*=\\(.*\\)" value)
                (cons (org-trim (match-string 1 value))
                      (org-trim (match-string 2 value)))))
            (org-babel-join-splits-near-ch
             61 (org-babel-balanced-split headers-arg 32)))))

(defun es-org-execute-request (jq-header shell-header &optional tablify request-data extra-headers)
  "Executes a request with parameters that are above the request.
Does not move the point."
  (interactive)
  (let* ((params (or (es--find-params)
                     `(,(es-get-request-method) . ,(es-get-url))))
         (url-request-method (encode-coding-string (car params) 'utf-8))
         (url (es--munge-url (cdr params)))
         (url-request-extra-headers
          (append
           es-default-headers
           extra-headers))
         (url-request-data (encode-coding-string request-data 'utf-8)))
    (when (es--warn-on-delete-yes-or-no-p url-request-method)
      (message "Issuing %s against %s [jq=%s, shell=%s, tablify=%s]"
               url-request-method url jq-header shell-header tablify)
      (let* ((buffer (url-retrieve-synchronously url))
             (http-warnings (with-current-buffer buffer (es-extract-warnings))))
        (unless (zerop (buffer-size buffer))
          (prog1
              (with-temp-buffer
                (if (not (<= 200
                             (with-current-buffer buffer
                               (url-http-parse-response))
                             299))
                    (insert-buffer buffer)
                  (when (and http-warnings (not (equal http-warnings "")))
                    (insert "// Warning: "
                            http-warnings
                            "\n"))
                  (url-insert buffer)
                  (ignore-errors (json-pretty-print-buffer))
                  (when jq-header
                    ;; Pull off any initial words in jq-header that begin with
                    ;; `-` to pass them to jq as command-line options.  The
                    ;; remaining jq-header text will be quoted as the jq
                    ;; filter.  Note that the regexp is not smart enough to
                    ;; handle quoted spaces in the options so those must be
                    ;; avoided.
                    ;; (rx string-start (zero-or-more (seq "-" (one-or-more (not (or " " "\t"))) (one-or-more (or " " "\t")))))
                    ;; "\\`\\(?:-[^	 ]+[	 ]+\\)*"
                    (let* ( (opts-re "\\`\\(\\(?:-[^	 ]+[	 ]+\\)*\\)\\(.*\\)")
                            (m (string-match opts-re jq-header))
                            (jq-options (match-string 1 jq-header))
                            (jq-filter (match-string 2 jq-header)))
                      (shell-command-on-region
                        (point-min)
                        (point-max)
                        (format "%s -r %s %s" es-jq-path jq-options (shell-quote-argument jq-filter))
                        (current-buffer)
                        t)))
                  (when shell-header
                    (shell-command-on-region
                     (point-min)
                     (point-max)
                     shell-header
                     (current-buffer)
                     t)))
                (if tablify
                    (es-parse-histogram-to-table (buffer-string) tablify)
                  (buffer-string)))
            (kill-buffer buffer)))))))

(defun org-babel-execute:es (body params)
  "Execute a block containing an Elasticsearch query with
org-babel.  This function is called by
`org-babel-execute-src-block'. If `es-warn-on-delete-query' is
set to true, this function will also ask if the user really wants
to do that."
  (with-temp-buffer
    (es-mode)
    (setq es-request-method (upcase (or (cdr (assoc :method params)) es-default-request-method)))
    (setq es-endpoint-url (or (cdr (assoc :url params)) es-default-url))
    (insert (org-babel-expand-body:es body params))
    (beginning-of-buffer)
    (let* ((headers (es-org--parse-headers (cdr (assoc :headers params))))
           (output (es-org-execute-request
                    (cdr (assoc :jq params))
                    (cdr (assoc :shell params))
                    (cdr (assoc :tablify params))
                    (es-get-request-body)
                    headers))
           (file (cdr (assoc :file params))))
      (ignore-errors
        (while (es-goto-next-request)
          (setq output
                (concat output
                        "\n"
                        (es-org-execute-request
                         (cdr (assoc :jq params))
                         (cdr (assoc :shell params))
                         (cdr (assoc :tablify params))
                         (es-get-request-body)
                         headers)))))
      (if file
          (with-current-buffer (find-file-noselect file)
            (delete-region (point-min) (point-max))
            (if (string-suffix-p ".org" file t)
                (progn (require 'org-json)
                       (insert (org-json-decode (json-read-from-string output) 1)))
              (insert output))
            (save-buffer))
        output))))

(provide 'ob-elasticsearch)
;;; ob-elasticsearch.el ends here
