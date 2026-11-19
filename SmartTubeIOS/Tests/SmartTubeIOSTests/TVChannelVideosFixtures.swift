import Foundation

// REAL capture (trimmed to 3 tiles, tracking params and menus removed): signed-out TVHTML5
// `browse` with browseId `VLUULFX6OQ3DkcsbYNE6H8uQQuVA` (a channel's "Videos tab" uploads
// playlist) against youtubei.googleapis.com, 2026-11. Signed out, so no resume overlay is
// present; resume-progress fixtures in TVChannelVideosTests are SHAPE-BASED.
enum TVChannelVideosFixtures {
    static let uploadsPlaylistPage: String = #"""
{
 "contents": {
  "tvBrowseRenderer": {
   "content": {
    "tvSurfaceContentRenderer": {
     "content": {
      "twoColumnRenderer": {
       "rightColumn": {
        "playlistVideoListRenderer": {
         "contents": [
          {
           "tileRenderer": {
            "style": "TILE_STYLE_YTLR_VERTICAL_LIST",
            "header": {
             "tileHeaderRenderer": {
              "thumbnail": {
               "thumbnails": [
                {
                 "url": "https://i.ytimg.com/vi/q6fgVVmdpgY/hqdefault.jpg",
                 "width": 480,
                 "height": 360
                }
               ]
              },
              "thumbnailOverlays": [
               {
                "thumbnailOverlayTimeStatusRenderer": {
                 "text": {
                  "accessibility": {
                   "accessibilityData": {
                    "label": "33 minutes, 58 seconds"
                   }
                  },
                  "simpleText": "33:58"
                 },
                 "style": "DEFAULT"
                }
               }
              ]
             }
            },
            "metadata": {
             "tileMetadataRenderer": {
              "title": {
               "simpleText": "$250,000 Hunger Games In Real Life"
              },
              "lines": [
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "text": {
                     "runs": [
                      {
                       "text": "MrBeast"
                      }
                     ]
                    }
                   }
                  }
                 ]
                }
               },
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "badge": {
                     "metadataBadgeRenderer": {
                      "style": "BADGE_STYLE_TYPE_SIMPLE",
                      "label": "4K"
                     }
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "accessibility": {
                      "accessibilityData": {
                       "label": "82 million views"
                      }
                     },
                     "simpleText": "82M views"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "•"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "4 days ago"
                    }
                   }
                  }
                 ]
                }
               }
              ]
             }
            },
            "onSelectCommand": {
             "watchEndpoint": {
              "videoId": "q6fgVVmdpgY",
              "playlistId": "UULFX6OQ3DkcsbYNE6H8uQQuVA",
              "playerParams": "iAQB0gcJCeoHAYcqIYzv"
             }
            },
            "contentId": "q6fgVVmdpgY",
            "contentType": "TILE_CONTENT_TYPE_VIDEO"
           }
          },
          {
           "tileRenderer": {
            "style": "TILE_STYLE_YTLR_VERTICAL_LIST",
            "header": {
             "tileHeaderRenderer": {
              "thumbnail": {
               "thumbnails": [
                {
                 "url": "https://i.ytimg.com/vi/_c2e1NcI3Sc/hqdefault_custom_2.jpg?sqp=CIyE_NcG&rs=AOn4CLDMbu8u2kh-u81vet4kFeIBcv2lpg",
                 "width": 480,
                 "height": 360
                }
               ]
              },
              "thumbnailOverlays": [
               {
                "thumbnailOverlayTimeStatusRenderer": {
                 "text": {
                  "accessibility": {
                   "accessibilityData": {
                    "label": "22 minutes, 28 seconds"
                   }
                  },
                  "simpleText": "22:28"
                 },
                 "style": "DEFAULT"
                }
               }
              ]
             }
            },
            "metadata": {
             "tileMetadataRenderer": {
              "title": {
               "simpleText": "Beat Professional Athlete, Win $100,000"
              },
              "lines": [
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "text": {
                     "runs": [
                      {
                       "text": "MrBeast"
                      }
                     ]
                    }
                   }
                  }
                 ]
                }
               },
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "badge": {
                     "metadataBadgeRenderer": {
                      "style": "BADGE_STYLE_TYPE_SIMPLE",
                      "label": "4K"
                     }
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "accessibility": {
                      "accessibilityData": {
                       "label": "100 million views"
                      }
                     },
                     "simpleText": "100M views"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "•"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "2 weeks ago"
                    }
                   }
                  }
                 ]
                }
               }
              ]
             }
            },
            "onSelectCommand": {
             "watchEndpoint": {
              "videoId": "_c2e1NcI3Sc",
              "playlistId": "UULFX6OQ3DkcsbYNE6H8uQQuVA",
              "playerParams": "iAQB"
             }
            },
            "contentId": "_c2e1NcI3Sc",
            "contentType": "TILE_CONTENT_TYPE_VIDEO"
           }
          },
          {
           "tileRenderer": {
            "style": "TILE_STYLE_YTLR_VERTICAL_LIST",
            "header": {
             "tileHeaderRenderer": {
              "thumbnail": {
               "thumbnails": [
                {
                 "url": "https://i.ytimg.com/vi/RE3_PGwDwhw/hqdefault_custom_2.jpg?sqp=CIyE_NcG&rs=AOn4CLBvyBSIQ7PWTJ1POUH5Nc3Xv4KrlA",
                 "width": 480,
                 "height": 360
                }
               ]
              },
              "thumbnailOverlays": [
               {
                "thumbnailOverlayTimeStatusRenderer": {
                 "text": {
                  "accessibility": {
                   "accessibilityData": {
                    "label": "43 minutes, 17 seconds"
                   }
                  },
                  "simpleText": "43:17"
                 },
                 "style": "DEFAULT"
                }
               }
              ]
             }
            },
            "metadata": {
             "tileMetadataRenderer": {
              "title": {
               "simpleText": "Lose 150 Lbs Together, Win $250,000"
              },
              "lines": [
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "text": {
                     "runs": [
                      {
                       "text": "MrBeast"
                      }
                     ]
                    }
                   }
                  }
                 ]
                }
               },
               {
                "lineRenderer": {
                 "items": [
                  {
                   "lineItemRenderer": {
                    "text": {
                     "accessibility": {
                      "accessibilityData": {
                       "label": "197 million views"
                      }
                     },
                     "simpleText": "197M views"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "•"
                    }
                   }
                  },
                  {
                   "lineItemRenderer": {
                    "text": {
                     "simpleText": "1 month ago"
                    }
                   }
                  }
                 ]
                }
               }
              ]
             }
            },
            "onSelectCommand": {
             "watchEndpoint": {
              "videoId": "RE3_PGwDwhw",
              "playlistId": "UULFX6OQ3DkcsbYNE6H8uQQuVA",
              "playerParams": "iAQB"
             }
            },
            "contentId": "RE3_PGwDwhw",
            "contentType": "TILE_CONTENT_TYPE_VIDEO"
           }
          }
         ],
         "continuations": [
          {
           "nextContinuationData": {
            "continuation": "CONT_TOKEN_1"
           }
          }
         ]
        }
       }
      }
     }
    }
   }
  }
 }
}
"""#
}
