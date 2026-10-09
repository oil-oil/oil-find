import OilFindApp
#if canImport(OilFindPro) && !OILFIND_FREE_BUILD
import OilFindPro
Application.run(appExtension: OilFindProExtension())
#else
Application.run()
#endif
