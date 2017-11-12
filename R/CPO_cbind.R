#' @include CPO_meta.R

#' @title \dQuote{cbind} the Result of multiple CPOs
#'
#' @description
#' Build a CPO that represents the operations of its input parameters,
#' performed in parallel and put together column wise.
#'
#' For example, to construct a \code{\link{Task}} that contains the original
#' data, as well as the data after scaling, one could do
#'
#' \code{task \%>>\% cpoCbind(NULLCPO, cpoScale())}
#'
#' The result of \code{cpoCbind} is itself a CPO which exports its constituents'
#' hyperparameters. CPOs with the same type / ID get combined automatically.
#' To get networks, e.g. of the form
#' \preformatted{
#'       ,-C--E-.
#'      /    /   \
#' A---B ---D-----F---G
#' }
#' one coul use the code
#' \preformatted{
#' initcpo = A \%>>\% B
#' route1 = initcpo \%>>\% D
#' route2 = cpoCbind(route1, initcpo \%>>\% C) \%>>\% E
#' result = cpoCbind(route1, route2) \%>>\% F \%>>\% G
#' }
#'
#' cpoCbind finds common paths among its arguments and combines them into one operation.
#' This saves computation and makes it possible for one exported hyperparameter to
#' influence multiple of \code{cpoCbind}'s inputs. However, if you want to use the same
#' operation with different parameters on different parts of \code{cpoCbind} input,
#' you must give these operations different IDs. If CPOs that could represent an identical CPO,
#' with the same IDs (or both with IDs absent) but different parameter settings or different
#' parameter exportations occur, an error will be thrown.
#'
#' @param ... [\code{CPO}]\cr
#'   The CPOs to cbind. Named arguments will result in the respective
#'   columns being prefixed with the name. This is highly recommended if there
#'   is any chance of name collision otherwise. it is possible to use the same
#'   name multiple times.
#' @param .cpos [\code{list} of \code{CPO}]\cr
#'   Alternatively, give the CPOs to cbind as a list. Default is \code{list()}.
#' @export
cpoCbind = function(..., .cpos = list()) {
  cpos = list(...)
  cpos = c(cpos, .cpos)

  assertList(cpos, types = "CPO", any.missing = FALSE)  # FIXME: require databound
  collectedprops = collectProperties(cpos, do.intersect = TRUE)

  # the graph representing the operations being performed.
  # types: SOURCE, CPO, CBIND. SOURCE has no parents, CPO has only one parent.
  # 'parents', 'children' identify other items by their index in the 'cpograph' list
  # items in graph are sorted so that parents always come before children, with the
  # "SOURCE" item at position 1.
  cpograph = list(makeCPOGraphItem(type = "SOURCE", parents = integer(0), children = integer(0), content = NULL))

  dangling = setNames(integer(0), character(0))
  for (cidx in seq_along(cpos)) {
    cname = names(cpos)[cidx]
    if (is.null(cname)) {
      cname = ""
    }
    newcpos = as.list(cpos[[cidx]])
    curparent = 1L
    for (cpoprim in newcpos) {
      if ("CPOCbind" %in% class(cpoprim)) {
        cpograph = uniteGraph(cpograph, curparent, cpoprim$par.vals[[".CPO"]], getHyperPars(cpoprim))
      } else {
        cpograph = c(cpograph, list(makeCPOGraphItem(type = "CPO", parents = curparent, children = integer(0), content = cpoprim)))
        cpograph[[curparent]]$children = c(cpograph[[curparent]]$children, length(cpograph))
      }
      curparent = length(cpograph)
    }
    if (length(newcpos)) {
      dangling = c(dangling, length(cpograph))
    } else {
      dangling = c(dangling, 1L)
    }
    names(dangling)[length(dangling)] = cname
  }
  cpograph = c(cpograph, list(makeCPOGraphItem(type = "CBIND", parents = unname(dangling), children = integer(0), content = names(dangling))))
  for (d in dangling) {
    cpograph[[d]]$children = c(cpograph[[d]]$children, length(cpograph))
  }
  dupparents = dangling[dangling %in% dangling[duplicated(dangling)]]
  dupnames = unique(names(dupparents)[duplicated(names(dupparents))])
  if (length(dupnames)) {
    stopf("Duplicating inputs must always have different names, but there are duplicated entries %s.",
      ifelse(all(dupnames == ""), "which are unnamed", collapse(Filter(function(x) x != "", dupnames), sep = ", ")))
  }

  if (length(cpos)) {
    cpograph = synchronizeGraph(cpograph)
  }

  allcpos = lapply(Filter(function(x) x$type == "CPO", cpograph), function(x) x$content)
  par.set = do.call(base::c, lapply(allcpos, getParamSet))
  par.vals = do.call(base::c, lapply(allcpos, getHyperPars))
  par.set = c(par.set, makeParamSet(makeUntypedLearnerParam(".CPO")))
  par.vals = c(par.vals, list(.CPO = cpograph))

  control = NULL  # pacify static code analyser

  addClasses(setCPOId(makeCPOExtended("cbind", .par.set = par.set, .par.vals = par.vals, .dataformat = "task",
    .properties = collectedprops$properties,
    .properties.adding = collectedprops$properties.adding,
    .properties.needed = collectedprops$properties.needed,
    .properties.target = collectedprops$properties.target,
    cpo.trafo = function(data, target, .CPO, ...) {
      args = list(...)
      ag = applyGraph(.CPO, data, TRUE, args)
      control = ag$graph
      ag$data
    }, cpo.retrafo = function(data, control, ...) {
      applyGraph(control, data, FALSE, NULL)$data
    })(), NULL), "CPOCbind")
}

# Iterate through the graph objects in order of dependency, apply each CPO to the data.
applyGraph = function(graph, data, is.trafo, args) {
  graph[[1]]$data[[1]] = data
  for (n in seq_along(graph)) {
    curgi = graph[[n]]
    outdata = switch(curgi$type,
      SOURCE = curgi$data[[1]],
      CPO = {
        assert(length(curgi$data) == 1)
        if (is.trafo) {
          ps = getParamSet(curgi$content)
          curcpo = setHyperPars(curgi$content, par.vals = subsetParams(args, ps))
        } else {
          curcpo = curgi$content
        }
        trafod = curgi$data[[1]] %>>% curcpo
        if (is.trafo) {
          curgi$content = retrafo(trafod)
          retrafo(trafod) = NULL
        }
        trafod
      },
      CBIND = {
        datas = curgi$data
        if (is.trafo) {
          datas = lapply(datas, function(x) getTaskData(x, target.extra = TRUE)$data)
        }
        assert(length(datas) == length(curgi$content))
        assert(!any(sapply(datas, is.null)))
        datas = lapply(seq_along(datas), function(i) {
          df = data.frame(datas[[i]])
          prefix = curgi$content[i]
          if (!is.null(prefix) && prefix != "" && length(df)) {
            names(df) = paste(prefix, names(df), sep = ".")
          }
          df
        })
        if (is.trafo) {
          datas = c(list(getTaskData(data, features = character(0))), datas)
        }
        cnames = unlist(lapply(datas, names))
        dupnames = cnames[duplicated(cnames)]
        if (length(dupnames)) {
          stopf("Names %s duplicated", collapse(unique(dupnames)))
        }
        datas = do.call(cbind, datas)
        if (is.trafo) {
          changeData(data, datas)
        } else {
          datas
        }
      })
    curgi$data = list()  # free some memory
    for (c in curgi$children) {
      insert.candidates = Filter(function(idx) {
        length(graph[[c]]$data) < idx || is.null(graph[[c]]$data[[idx]])
      }, which(graph[[c]]$parents == n))
      assert(length(insert.candidates) >= 1)
      graph[[c]]$data[[insert.candidates[1]]] = outdata
    }
    graph[[n]] = curgi
    if (!length(curgi$children)) {
      assert(n == length(graph))
      assert(curgi$type == "CBIND")
      return(list(data = outdata, graph = graph))
    }
  }
}

#' @export
# This is more for debugging; the user should not see the "graph" in itself
# (and uses only print.CPOCbind), since the graph itself is hidden quite deeply.
print.CPOGraphItem = function(x, ...) {
  catf("CPOGraphItem [%s] %s P[%s] C[%s]", x$type,
    switch(x$type, SOURCE = "", CPO = getCPOName(x$content), CBIND = paste0("{", collapse(x$content), "}"), "INVALID"),
    collapse(x$parents), collapse(x$children))
}

#' @export
# print the CPOCbind object, including the graph.
print.CPOCbind = function(x, ...) {
  NextMethod("print")
  par.vals = getHyperPars(x)
  graph = par.vals$.CPO
  descriptions = sapply(graph[-1], function(x) {
    switch(x$type, CBIND = paste0("CBIND[", collapse(x$content), "]"),
      CPO = {
        cpo = x$content
        cpo = setHyperPars(cpo, par.vals = par.vals[intersect(names(par.vals), names(getParamSet(cpo)$pars))])
        utils::capture.output(print(x$content))
      }, "INVALID")
  })
  offset = length(graph) + 1
  children = lapply(graph[-1], function(x) offset - setdiff(x$parents, 1))
  printGraph(rev(children), rev(descriptions))
}

# Creator for a single graph item used in CPOCbind.
# type is 'SOURCE' (the data goes in here; a graph has only one of these. has no parents, one or more children.),
#   'CPO' (the node represents a CPO applied to data; has exactly one parent and one child)
#   or 'CBIND' (node that applies 'cbind' to incoming data streams; has multiple parents, at most one child.)
# parents is of type 'integer', a vector of indices of parent objects in the containing list of CPOGraphItems
#   'SOURCE' CPOGraphItems have no parents, so it is an integer(0) in that case.
# children is an integer vector pointing to the node's children.
# content: the 'content' of the node: either the CPO in a "CPO" node, or the names assigned to each created block for a 'CBIND' block.
makeCPOGraphItem = function(type, parents, children, content) {
  assertChoice(type, c("SOURCE", "CPO", "CBIND"))
  assertInteger(parents)
  assertInteger(children)
  if (type == "CPO") {
    assertClass(content, "CPO")
  } else if (type == "CBIND") {
    assertCharacter(content)
  }
  makeS3Obj("CPOGraphItem",
    type = type, parents = parents, children = children, content = content, data = NULL)
}

#' @export
setCPOId.CPOCbind = function(cpo, id) {
  if (!is.null(id)) {
    stop("Cannot set CPO ID of CPOCbind object.")
  }
  cpo
}

# pretty-print the graph of a cpoCbind object.
# Each node of the graph is implicitly numbered 1..n, so only
# the edges, and the descriptions, of each node need to be given.
# parameters:
#   children: list of numeric vectors, indicating child indices
#             node 1 is assumed to not have any parents.
#   descriptions: Descriptions to print
#   width: maximum printing width
printGraph = function(children, descriptions, width = getOption("width")) {
  # get list of indices of parents
  parents = replicate(length(children), integer(0), simplify = FALSE)
  for (idx in seq_along(children)) {
    for (child in children[[idx]]) {
      parents[[child]] = c(parents[[child]], idx)
    }
  }
  pcopy = parents

  # topological sort
  queue = 1
  curidx = 1
  ordereds = numeric(length(children))

  lanes = 0L

  mainlines = character(0)
  paddinglines = character(0)

  while (length(queue)) {
    paddinglines = c(collapse(ifelse(lanes, "|", " "), sep = " "), paddinglines)

    current = queue[1]
    queue = queue[-1]
    ordereds[curidx] = current
    curidx = curidx + 1

    candidates = children[[current]]
    for (cand in candidates) {
      parents[[cand]] = setdiff(parents[[cand]], current)
      if (!length(parents[[cand]])) {
        queue = c(queue, cand)
      }
    }

    lanes.in = which(lanes %in% pcopy[[current]])  # each lane contains the idx of the vertex out of which it comes
    for (l in lanes.in) {  # check if any lane's vertex's last child is being printed
      children[[lanes[l]]] = setdiff(children[[lanes[l]]], current)
      if (!length(children[[lanes[l]]])) {
        lanes[l] = 0
      }
    }
    first.candidates = intersect(which(lanes == 0), lanes.in)
    second.candidates = which(lanes == 0)
    lane.out = c(first.candidates, second.candidates)[1]
    if (lane.out == length(lanes)) {
      lanes = c(lanes, 0)
    }
    lanes[lane.out] = ifelse(length(children[[current]]), current, 0)
    first.interesting.lane = min(lanes.in, lane.out)
    last.interesting.lane = max(lanes.in, lane.out)
    outputchr = collapse(sapply(seq_along(lanes), function(li) {
      lane = lanes[li]
      if (li == lane.out) {
        chr1 = "O"
      } else if (li %in% lanes.in) {
        chr1 = "+"
      } else if (li < last.interesting.lane && li > first.interesting.lane) {
        chr1 = "-"
      } else if (lane != 0) {
        chr1 = "|"
      } else {
        chr1 = " "
      }
      if (li < last.interesting.lane && li >= first.interesting.lane) {
        if (li == lane.out) {
          chr2 = ">"
        } else if (li == lane.out - 1) {
          chr2 = "<"
        } else {
          chr2 = "-"
        }
      } else {
        chr2 = " "
      }
      paste0(chr1, chr2)
    }), sep = "")
    mainlines = c(outputchr, mainlines)
  }
  ordereds = rev(ordereds)

  graphwidth = length(lanes) * 2
  textwidth = width - graphwidth

  if (textwidth > 20) {
    for (i in seq_along(mainlines)) {
      itemtext = c(strwrap(descriptions[ordereds[i]], width = textwidth), "")
      itemtext = c(paste0(mainlines[i], itemtext[1]), paste0(paddinglines[i], itemtext[-1]))
      cat(itemtext, sep = "\n")
    }
  } else {
    for (i in seq_along(mainlines)) {
      itemtext = c(paste(mainlines[i], i), paddinglines[i])
      cat(itemtext, sep = "\n")
    }
    for (i in seq_along(mainlines)) {
      itemtext = strwrap(paste(i, descriptions[ordereds[i]], sep = ": "), width = textwidth)
      cat(itemtext, sep = "\n")
    }
  }
}

# This connects two cpoCbind operations together.
# If CBIND_1 is a graph (SOURCE -> CPOA -> SINK) and (SOURCE -> CPOB -> SINK)
# and CBIND_2 is a graph (SOURCE -> CPOC -> SINK) and (SOURCE -> CBIND_1 (!!!) -> SINK)
# then we here we incorporate the graph of CBIND_1 into CBIND_2 to get
# (SOURCE -> CPOC -> SINK), (SOURCE -> CPOA -> SINK) and (SOURCE -> CPOB -> SINK).
# Graphs that have been 'united' also need to be 'synchronized' (see `synchronizeGraph`) to remove duplicate entries.
# @param cpograph [list of CPOGraphItem] the "parent" graph where the `childgraph` should be included
# @param sourceIdx [numeric(1)] the index into `cpograph` of the element that will be the data source for `childgraph`
# @param childgraph [list of CPOGraphItem] the "child" graph to add to `cpograph`
# @param par.vals [list] list of parameter values to set `childgraph` elements to
# @return [list of CPOGraphItem] the updated graph.
uniteGraph = function(cpograph, sourceIdx, childgraph, par.vals) {
  idxoffset = length(cpograph) - 1

  for (cidx in seq_along(childgraph)) {
    if (cidx == 1) {  # skip "SOURCE" element
      next
    }
    newidx = cidx + idxoffset
    childitem = childgraph[[cidx]]
    for (pidx in seq_along(childitem$parents)) {
      parent = childitem$parents[pidx]
      if (parent == 1) {
        cpograph[[sourceIdx]]$children = c(cpograph[[sourceIdx]]$children, newidx)
        childitem$parents[pidx] = sourceIdx
      } else {
        childitem$parents[pidx] = idxoffset + parent
      }
    }
    childitem$children = childitem$children + idxoffset

    if ("CPO" %in% class(childitem$content)) {
      childitem$content = setHyperPars(childitem$content, par.vals = par.vals[intersect(names(par.vals), names(getParamSet(childitem$content)$pars))])
    }
    cpograph = c(cpograph, list(childitem))
  }
  cpograph
}

# This checks the graph for operations that can be combined into one operation.
# If we have e.g.
# SOURCE -+-> CPOA -> CPOB -.
#          \                 \
#           `-> CPOA -> CPOC -+-> SINK
# then we will find CPOA to be a duplicate and get the graph
# SOURCE -> CPOA -+-> CPOB -.
#                  \         \
#                   `-> CPOC -+-> SINK
# @param cpograph [list of CPOGraphItem] the graph to simplify
# @return [list of CPOGraphItem] the simplified graph
synchronizeGraph = function(cpograph) {
  newgraph = list()
  for (oldgraph.index in seq_along(cpograph)) {
    graphitem = cpograph[[oldgraph.index]]
    graphitem$children = integer(0)
    graphitem$parents = viapply(graphitem$parents, function(i) cpograph[[i]])
    if (oldgraph.index == 1) {
      assert(length(graphitem$parents) == 0)
      siblings = integer(0)
    } else {
      assert(length(graphitem$parents) > 0)
      siblings = newgraph[[graphitem$parents[1]]]$children
    }
    # see if graphitem equals one of its siblings. We need only to check the first paren'ts siblings,
    # since equality <=> same parents
    matchingsib = 0
    for (s in siblings) {
      sib = newgraph[[s]]
      if (sib$type != graphitem$type) {
        next
      }
      assertChoice(sib$type, c("CPO", "CBIND"))
      if (sib$type == "CPO") {
        if (getCPOName(sib$content) != getCPOName(graphitem$content) || !identical(getCPOId(sib$content), getCPOId(graphitem$content))) {
          next
        }
        if (!identical(getHyperPars(sib$content), getHyperPars(graphitem$content))) {
          stopf("Error: Two CPOS %s are ambiguously identical but have different hyperparameter settings.",
                sib$content$debug.name)
        }
        # FIXME: whenever more distinguishing hidden state comes along, it needs to be checked here.
        assert(identical(sib$content, graphitem$content))
      } else { # CBIND
        if (!identical(sib$content, graphitem$content)) {
          next
        }
      }
      assert(!matchingsib || matchingsib == s)  # the new sibs are supposed to be unique each (otherwise we missed an opportunity to sync)
      matchingsib = s
    }
    if (matchingsib) {
      cpograph[[oldgraph.index]] = matchingsib
    } else {
      newgraph = c(newgraph, list(graphitem))
      curidx = length(newgraph)
      for (p in graphitem$parents) {
        newgraph[[p]]$children = c(newgraph[[p]]$children, curidx)
      }
      cpograph[[oldgraph.index]] = curidx
    }
  }
  newgraph
}

registerCPO(cpoCbind, "meta", NULL, "Combine multiple CPO operations by joining their outputs column-wise.")