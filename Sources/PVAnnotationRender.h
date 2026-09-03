/*
 * PVAnnotationRender.h -- drawing the content CGContextDrawPDFPage leaves out.
 *
 * Quartz draws a page's content stream and nothing else. Annotations are not
 * part of that stream: they are separate objects carrying their own appearance
 * streams, and a viewer is expected to draw them itself. Postview never did, so
 * a page whose visible content lives in annotations came out BLANK -- silently,
 * with no failure anywhere to notice.
 *
 * That is not a corner case. `Operating Systems.pdf` (OSTEP, 675 pages) puts
 * its whole cover there: page 1's content stream is 30 bytes of empty marked
 * content and its 33 annotations carry the title. Measured 2026-09-03, page 1
 * renders at 0.0000% ink through CoreGraphics and 1.34% through PDFKit. Two
 * pages of 675 -- and they are the two the reader sees first.
 *
 * CoreGraphics has no public API that draws a form XObject, so the appearance
 * streams cannot be executed directly; PDFKit is the only way to draw them
 * without writing a content-stream interpreter. PDFKit is AppKit-based, and on
 * 10.9 -[PDFPage drawWithBox:] is the only drawing method there is -- it takes
 * the current NSGraphicsContext, so AppKit has to be in the process.
 *
 * Which the Makefile forbids, for a good reason it states plainly: the helper
 * "must never bring AppKit into a process whose whole purpose is to be killed
 * and restarted". So nothing here is linked. Quartz is dlopen'd the first time
 * a page actually needs it and never at all otherwise, which is the same
 * pattern PVPowerSymbols() uses. A document without annotations pays nothing:
 * not a byte of AppKit is mapped, and the fast path is untouched.
 */

#ifndef PV_ANNOTATION_RENDER_H
#define PV_ANNOTATION_RENDER_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/*
 * Teach PVRenderCore to draw this document's annotated pages through PDFKit.
 *
 * Called once by the helper's main(), after the document is opened and before
 * any command is read. `documentPath` is the file the helper was given; PDFKit
 * opens it a second time, lazily, the first time a page actually needs it, so a
 * document with no annotations never opens it at all.
 *
 * Nothing is linked and nothing is loaded by this call itself. It only installs
 * the hook; Quartz is dlopen'd on first use and never if there is no use.
 */
void PVInstallAnnotationDrawHook(NSString *documentPath);

#endif /* PV_ANNOTATION_RENDER_H */
