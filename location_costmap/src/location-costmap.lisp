;;; Copyright (c) 2010, Lorenz Moesenlechner <moesenle@in.tum.de>
;;; All rights reserved.
;;; 
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;; 
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;     * Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;     * Neither the name of the Intelligent Autonomous Systems Group/
;;;       Technische Universitaet Muenchen nor the names of its contributors 
;;;       may be used to endorse or promote products derived from this software 
;;;       without specific prior written permission.
;;; 
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.

(in-package :location-costmap)

;;; The class location-costmap is central to this code, and the
;;; cost-functions it contains. The cost functions are used for
;;; sampling. The cost functions are combined by multiplying
;;; corresponding values for equal X- and Y-coordinates and finally
;;; normalizing the resulting map to be a valid probability
;;; distribution, i.e. to have a sum of 1. Therefore the values
;;; returned should never be negative, and at least some must be
;;; non-zero

(define-condition no-cost-functions-registered (error) ())

;; A location costmap is a 2d grid map that defines for each x,y point
;; a cost value. It provides an API to sample random poses by
;; generating random x and y points and using further generators to
;; set the z value and the orientation of the pose.
(defclass location-costmap (occupancy-grid-metadata)
  ((cost-map :documentation "private slot that gets filled with data by the cost-functions")
   (cost-functions :reader cost-functions :initarg :cost-functions
                   :initform nil
                   :documentation "Sequence of cons (closure . name)
                                   where the closures take an x and a
                                   y coordinate and return the
                                   corresponding cost in the interval
                                   [0;1]. name must be something for
                                   which costmap-generator-name->score
                                   is defined, and it must be unique
                                   for this costmap, as functions with
                                   the same name count as
                                   duplicates. To set this slot, use
                                   register-cost-function
                                   preferably.")
   (height-generator
    :initform nil :initarg :height-generator :reader height-generator
    :documentation "A callable object that takes two parameters, X and
                    Y and returns a list of valid height
                    values (i.e. Z coordinate of the generated
                    pose). The function needs to be deterministic and
                    is used whenever a costmap sample is generated. If
                    not set, a constant value of 0.0d0 is returned.")
   (orientation-generators
    :initform nil :initarg :orientation-generators :reader orientation-generators
    :documentation "A sequence of callable objects that take three
                    parameters, X, Y and the return value of the
                    previous orientation generators. Each of the
                    functions returns a (lazy-) list of
                    quaternions. The function is not required to be
                    deterministic and called whenever a new sample is
                    generated.")))

(defgeneric get-cost-map (map)
  (:documentation "Returns the costmap as a two-dimensional array of
  FLOAT."))

(defgeneric get-map-value (map x y)
  (:documentation "Returns the cost of a specific pose."))

(defgeneric register-cost-function (map fun name)
  (:documentation "Registers a new cost function. `fun' is a function
  object that accepts two parameters, X and Y and that returns a
  number within the interval [0;1].  `name' is a unique identifier for
  which the method COSTMAP-GENERATOR-NAME->SCORE is defined and is
  used to order the different cost functions before the costmap is
  calculated."))

(defgeneric register-height-generator (costmap generator)
  (:documentation "Registers a height generator in the costmap"))

(defgeneric register-orientation-generator (costmap generator)
  (:documentation "Registers an orientation generator in the
  costmap"))

(defgeneric gen-costmap-sample-point (map)
  (:documentation "Draws a sample from the costmap `map' interpreted
  as a probability function and returns it as CL-TRANSFORMS:3D-VECTOR"))

(defgeneric costmap-samples (map)
  (:documentation "Returns the lazy-list of randomly generated costmap
  samples, i.e. a lazy-list of instances of type CL-TRANSFORMS:POSE"))

(defgeneric costmap-generator-name->score (name)
  (:documentation "Returns the score for the costmap generator with
  name `name'. Greater scores result in earlier evaluation.")
  (:method ((name number))
    name))

(defmethod get-cost-map ((map location-costmap))
  "Returns the costmap matrix of `map', i.e. if not generated yet,
calls the generator functions and runs normalization."
  (unless (cost-functions map)
    (error 'no-cost-functions-registered))
  (with-slots (width height origin-x origin-y resolution) map
    (unless (slot-boundp map 'cost-map)
      (setf (slot-value map 'cost-functions)
            (sort (remove-duplicates (slot-value map 'cost-functions)
                                     :key #'generator-name)
                  #'> :key (compose
                            #'costmap-generator-name->score
                            #'generator-name)))
      (let ((new-cost-map (cma:make-double-matrix
                           (round (/ width resolution))
                           (round (/ height resolution))
                           :initial-element 1.0d0))
            (sum 0.0d0))
        (dolist (generator (cost-functions map))
          (setf new-cost-map (generate generator new-cost-map map)))
        (dotimes (row (cma:height new-cost-map))
          (dotimes (column (cma:width new-cost-map))
            (incf sum (aref new-cost-map row column))))
        (when (= sum 0)
          (error 'invalid-probability-distribution))
        (setf (slot-value map 'cost-map) (cma:m./ new-cost-map sum))))
    (slot-value map 'cost-map)))

(defmethod get-map-value ((map location-costmap) x y)
  (aref (get-cost-map map)
        (truncate (- y (slot-value map 'origin-y))
                  (slot-value map 'resolution))
        (truncate (- x (slot-value map 'origin-x))
                  (slot-value map 'resolution))))

(defmethod register-cost-function ((map location-costmap) (function function) name)
  (push (make-instance 'function-costmap-generator
          :name name :generator-function function)
        (slot-value map 'cost-functions)))

(defmethod register-cost-function
    ((map location-costmap) (generator costmap-generator) name)
  (setf (slot-value generator 'name) name)
  (push generator (slot-value map 'cost-functions)))

(defmethod register-height-generator ((map location-costmap) generator)
  (with-slots (height-generator) map
    (setf height-generator generator)))

(defmethod register-orientation-generator ((map location-costmap) generator)
  (with-slots (orientation-generators) map
    (pushnew generator orientation-generators)))

(defun merge-costmaps (cm-1 &rest costmaps)
  "merges cost functions and copies one height-map, returns one costmap"
  (etypecase cm-1
    (list (apply #'merge-costmaps (append (force-ll cm-1) costmaps)))
    (location-costmap
       ;; Todo: assert equal size of all costmaps
     (make-instance 'location-costmap
       :width (width cm-1)
       :height (height cm-1)
       :origin-x (origin-x cm-1)
       :origin-y (origin-y cm-1)
       :resolution (resolution cm-1)
       :cost-functions (reduce #'append (mapcar #'cost-functions costmaps)
                               :initial-value (cost-functions cm-1))
       :height-generator (some #'height-generator (cons cm-1 costmaps))
       :orientation-generators (mapcan (compose #'copy-list #'orientation-generators) (cons cm-1 costmaps))))))

(defun generate-height (map x y &optional (default 0.0d0))
  (or
   (when (height-generator map)
     (let ((heights (generate-heights map x y)))
       (when heights
         (random-elt heights))))
   default))

(defun generate-heights (map x y)
  (when (height-generator map)
    (funcall (height-generator map) x y)))

(defun generate-orientations (map x y
                              &optional (default (list (cl-transforms:make-identity-rotation))))
  (or (when (orientation-generators map)
        (reduce (lambda (solution function)
                  (funcall function x y solution))
                (orientation-generators map) :initial-value nil))
      default))

(defmethod gen-costmap-sample-point ((map location-costmap))
  (let ((cost-map (get-cost-map map)))
    (declare (type cma:double-matrix cost-map))
    (destructuring-bind (column row)
        (cma:sample-from-distribution-matrix cost-map)
      (with-slots (origin-x origin-y resolution) map
        (let* ((x (+ (* column resolution) origin-x))
               (y (+ (* row resolution) origin-y))
               (z (generate-height map x y)))
          (cl-transforms:make-3d-vector x y z))))))

(defmethod costmap-samples ((map location-costmap))
  (lazy-mapcan (lambda (sample-point)
                 (lazy-mapcar (lambda (orientation)
                                (tf:make-pose sample-point orientation))
                              (generate-orientations
                               map
                               (cl-transforms:x sample-point)
                               (cl-transforms:y sample-point))))
               (lazy-list ()
                 (cont (gen-costmap-sample-point map)))))
