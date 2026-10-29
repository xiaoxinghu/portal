;;; portal.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-

;; Author: Xiaoxing Hu <hi@xiaoxing.dev>
;; Maintainer: Xiaoxing Hu <hi@xiaoxing.dev>
;; URL: https://github.com/xiaoxinghu/portal
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: terminals, hypermedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The package root.  Loading it loads every Portal feature; the commands are
;; autoloaded from the feature files.  Portal's native module and app host are
;; built from this package's sources: the first native command offers to build
;; them, and `portal-build' builds them on request.

;;; Code:

;; Support loading this entry point by absolute path without prior package
;; setup.  Transitive and deferred sibling requires need the same directory,
;; while compiling too.  `macroexp-file-name' names this file in both cases,
;; even when another file's loading compiles it.
(eval-and-compile
  (add-to-list 'load-path (file-name-directory (or (macroexp-file-name) buffer-file-name))))

(require 'portal-build)
(require 'portal-web)
(require 'portal-web-bookmark)
(require 'portal-terminal)
(require 'portal-excalidraw)

;; Registers nothing until `portal-global-shortcut-set' is called.
(require 'portal-global-shortcut)

;; Posts nothing until `portal-post-key' is called.
(require 'portal-system)

(defcustom portal-terminal-consult-auto-enable t
  "Whether loading Portal and Consult enables their terminal integration.
Set this to nil before loading either package to opt out.  The integration
can still be enabled or disabled with `portal-terminal-consult-mode'."
  :type 'boolean
  :group 'portal-terminal)

(declare-function portal-terminal-consult-mode "portal-terminal-consult" (&optional arg))

(with-eval-after-load 'consult
  (when portal-terminal-consult-auto-enable
    (require 'portal-terminal-consult)
    (portal-terminal-consult-mode 1)))

(provide 'portal)
;;; portal.el ends here
