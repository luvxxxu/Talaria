import Foundation
import TalariaBridge

setvbuf(stdout, nil, _IOLBF, 0)
let status = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
